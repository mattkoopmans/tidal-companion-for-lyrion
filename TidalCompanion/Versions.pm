package Plugins::TidalCompanion::Versions;

# Versions of an album: the copies in the library (local folders and TIDAL
# albums) with the same artist and title, version information ignored, plus
# any merged into them by hand, minus any separated by hand.
#
# Each group of versions has a default: the one chosen by hand, or else the
# best one (see Rules::pickDefaultVersion: lossless, most tracks, own files
# before TIDAL). Playing any other version plays the default instead, and
# the library view without lossy duplicates hides the others. A version only
# gives way to the default when at least 80% of its tracks have a partner
# there, so a live recording sharing a studio album's title is left alone.
#
# Choices made by hand are kept by TIDAL album ID or folder, which survive a
# rescan; library IDs don't.

use strict;

use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TidalCompanion::Library;
use Plugins::TidalCompanion::Rules qw(albumKey artistKey coversAlbum isLossy matchTracks pickDefaultVersion);

my $log   = logger('plugin.tidalcompanion');
my $prefs = preferences('plugin.tidalcompanion');

my ($groups, $groupOf, $versionOf, %redirects);

my %FORMAT_NAMES = (
	flc => 'FLAC', alc => 'ALAC', mp3 => 'MP3', mp4 => 'AAC', aac => 'AAC',
	ape => 'APE', wvp => 'WavPack', mpc => 'Musepack', ogg => 'Ogg Vorbis',
	ops => 'Opus', wma => 'WMA', aif => 'AIFF', wav => 'WAV', dsf => 'DSD', dff => 'DSD',
);

sub clearCache {
	undef $groups;
	undef $groupOf;
	undef $versionOf;
	%redirects = ();
}

sub groupKey {
	my ($artist, $title) = @_;
	return artistKey($artist) . '|' . albumKey($title);
}

# Hand-made changes to the groups: { descriptor => group key }. A key
# starting with "own:" keeps that version on its own.
sub _overrides { $prefs->get('versionGroups') || {} }
sub _defaults  { $prefs->get('defaultVersions') || {} }

# group key => [ version ], each version
# { id, title, year, artist, source => 'local' | 'tidal', formats, tracks,
#   lossy, descriptor, naturalKey, override }
sub _groups {
	return $groups if $groups;

	my $rows = Slim::Schema->dbh->selectall_arrayref(q{
		SELECT al.id, al.title, al.year, al.extid, c.name, t.url, t.content_type, t.lossless
		FROM albums al
		JOIN contributors c ON c.id = al.contributor
		JOIN tracks t ON t.album = al.id
		WHERE t.audio = 1 AND (t.url LIKE 'file:%' OR t.url LIKE 'tidal://%')
	}) || [];

	my %albums;
	foreach my $row (@$rows) {
		my ($id, $title, $year, $extid, $artist, $url, $type, $lossless) = @$row;

		my $album = $albums{$id} ||= {
			id => $id, title => $title, year => $year, extid => $extid, artist => $artist,
			key => groupKey($artist, $title),
			file => 0, tidal => 0, lossyTracks => 0, types => {},
		};

		if ($url =~ /^tidal:/) {
			$album->{tidal}++;
		}
		else {
			$album->{file}++;
			$album->{firstUrl} = $url if !$album->{firstUrl} || $url lt $album->{firstUrl};
		}

		$album->{lossyTracks}++ if isLossy($type, $lossless);
		$album->{types}->{ $FORMAT_NAMES{lc($type || '')} || uc($type || '?') } = 1;
	}

	my $overrides = _overrides();
	my (%result, %of, %version);

	foreach my $album (values %albums) {
		# an album holding both files and TIDAL tracks isn't a version of anything
		next if $album->{file} && $album->{tidal};

		my $source = $album->{tidal} ? 'tidal' : 'local';
		my $descriptor = $source eq 'tidal'
			? ($album->{extid} || '')
			: do { (my $dir = $album->{firstUrl}) =~ s{/[^/]*$}{/}; $dir };

		my $override = length $descriptor ? $overrides->{$descriptor} : undef;
		my $key = $override || $album->{key};
		my $tracks = $album->{file} + $album->{tidal};

		my $version = {
			id         => $album->{id},
			title      => $album->{title},
			year       => $album->{year},
			artist     => $album->{artist},
			source     => $source,
			formats    => join('/', sort keys %{ $album->{types} }),
			tracks     => $tracks,
			lossy      => $album->{lossyTracks} == $tracks ? 1 : 0,
			descriptor => $descriptor,
			naturalKey => $album->{key},
			override   => $override,
		};

		push @{ $result{$key} }, $version;
		$of{ $album->{id} } = $key;
		$version{ $album->{id} } = $version;
	}

	# a steady order: oldest first, then TIDAL before local
	foreach my $versions (values %result) {
		@$versions = sort {
			($a->{year} || 9999) <=> ($b->{year} || 9999)
			|| ($a->{source} eq 'tidal' ? 0 : 1) <=> ($b->{source} eq 'tidal' ? 0 : 1)
			|| $a->{id} <=> $b->{id}
		} @$versions;
	}

	$groupOf = \%of;
	$versionOf = \%version;
	return $groups = \%result;
}

# The versions of album $albumId, itself included, and the group key.
sub versionsOf {
	my ($class, $albumId) = @_;

	my $groups = _groups();
	my $key = $groupOf->{$albumId} || return ([], undef);

	return ($groups->{$key} || [], $key);
}

sub version {
	my ($class, $albumId) = @_;
	_groups();
	return $versionOf->{$albumId};
}

# --- defaults ----------------------------------------------------------------------

# The ID of the version chosen by hand as default for group $key, if any.
sub chosenDefault {
	my ($class, $key) = @_;

	my $descriptor = _defaults()->{$key} || return;
	my $versions = _groups()->{$key} || return;

	my ($version) = grep { $_->{descriptor} eq $descriptor } @$versions;
	return $version ? $version->{id} : undef;
}

# The ID of the default version of group $key: chosen by hand, or automatic.
sub defaultOf {
	my ($class, $key) = @_;

	return unless $key;

	my $versions = _groups()->{$key} || return;
	return unless @$versions > 1;

	if (my $chosen = $class->chosenDefault($key)) {
		return $chosen;
	}

	my $best = pickDefaultVersion(@$versions);
	return $best ? $best->{id} : undef;
}

sub setDefault {
	my ($class, $albumId) = @_;

	my ($versions, $key) = $class->versionsOf($albumId);
	my $version = $class->version($albumId);
	return 0 unless $key && $version && length $version->{descriptor};

	$prefs->set('defaultVersions', { %{ _defaults() }, $key => $version->{descriptor} });

	%redirects = ();
	return 1;
}

sub clearDefault {
	my ($class, $key) = @_;

	my $defaults = { %{ _defaults() } };
	delete $defaults->{$key};
	$prefs->set('defaultVersions', $defaults);

	%redirects = ();
}

# --- merging and separating by hand -----------------------------------------------------

sub _setOverride {
	my ($descriptor, $key) = @_;

	my $overrides = { %{ _overrides() } };

	if (defined $key) {
		$overrides->{$descriptor} = $key;
	}
	else {
		delete $overrides->{$descriptor};
	}

	$prefs->set('versionGroups', $overrides);
	clearCache();
}

# Makes album $albumId a version of album $targetId.
sub merge {
	my ($class, $albumId, $targetId) = @_;

	my $version = $class->version($albumId) || return 0;
	my (undef, $targetKey) = $class->versionsOf($targetId);
	return 0 unless $targetKey && length $version->{descriptor};

	# merged back where it belongs anyway: just drop the override
	_setOverride($version->{descriptor}, $targetKey eq $version->{naturalKey} ? undef : $targetKey);
	return 1;
}

# Takes album $albumId out of its versions.
sub separate {
	my ($class, $albumId) = @_;

	my $version = $class->version($albumId) || return 0;
	return 0 unless length $version->{descriptor};

	# merged by hand: undoing the merge puts it back where it came from
	if ($version->{override} && $version->{override} !~ /^own:/) {
		_setOverride($version->{descriptor}, undef);
	}
	else {
		_setOverride($version->{descriptor}, 'own:' . $version->{descriptor});
	}

	return 1;
}

# Undoes a separation by hand: the album goes back to its versions.
sub rejoin {
	my ($class, $albumId) = @_;

	my $version = $class->version($albumId) || return 0;
	return 0 unless $version->{override};

	_setOverride($version->{descriptor}, undef);
	return 1;
}

sub isSeparated {
	my ($class, $albumId) = @_;
	my $version = $class->version($albumId) || return 0;
	return ($version->{override} || '') =~ /^own:/ ? 1 : 0;
}

sub isMerged {
	my ($class, $albumId) = @_;
	my $version = $class->version($albumId) || return 0;
	return $version->{override} && $version->{override} !~ /^own:/ ? 1 : 0;
}

# Albums that album $albumId could be merged with: other groups by the same
# artist, then groups by others with a similar title. Returns
# [ { id, title, artist, count } ], one album standing for each group.
sub mergeCandidates {
	my ($class, $albumId) = @_;

	my $version = $class->version($albumId) || return [];
	my (undef, $ownKey) = $class->versionsOf($albumId);

	my ($artist, $album) = split /\|/, $version->{naturalKey}, 2;

	my (@sameArtist, @similar);
	while (my ($key, $versions) = each %{ _groups() }) {
		next if $key eq $ownKey;

		my $representative = $versions->[0];
		my ($otherArtist, $otherAlbum) = split /\|/, $representative->{naturalKey}, 2;

		my $entry = {
			id     => $representative->{id},
			title  => $representative->{title},
			artist => $representative->{artist},
			count  => scalar @$versions,
		};

		if (grep { (split /\|/, $_->{naturalKey})[0] eq $artist } @$versions) {
			push @sameArtist, $entry;
		}
		elsif (length $album >= 4 && length $otherAlbum >= 4
			&& (index($otherAlbum, $album) == 0 || index($album, $otherAlbum) == 0)) {
			push @similar, $entry;
		}
	}

	return [
		(sort { lc $a->{title} cmp lc $b->{title} } @sameArtist),
		(sort { lc $a->{title} cmp lc $b->{title} } @similar),
	];
}

# --- where an album's tracks play from -----------------------------------------------

sub _playable {
	my ($albumId) = @_;
	return [ grep { $_->{url} =~ /^(?:file|tidal):/ } @{ Plugins::TidalCompanion::Library->tracksOf($albumId) } ];
}

# For album $albumId: { album => ID, tracks => { track ID => track ID } } if its
# tracks play from the default version, undef if they play as they are.
sub redirect {
	my ($class, $albumId) = @_;

	return $redirects{$albumId} if exists $redirects{$albumId};

	my $result;
	my (undef, $key) = $class->versionsOf($albumId);

	if (my $default = $class->defaultOf($key)) {
		if ($default != $albumId) {
			my $own = _playable($albumId);
			my $map = matchTracks($own, _playable($default));
			$result = { album => $default, tracks => $map } if coversAlbum(scalar keys %$map, scalar @$own);
		}
	}

	return $redirects{$albumId} = $result;
}

# True if the library view without lossy duplicates leaves album $albumId out.
sub isHidden {
	my ($class, $albumId) = @_;
	return $class->redirect($albumId) ? 1 : 0;
}

sub hiddenAlbumIds {
	my ($class) = @_;

	return grep { $class->isHidden($_) } map { map { $_->{id} } @$_ } grep { @$_ > 1 } values %{ _groups() };
}

1;
