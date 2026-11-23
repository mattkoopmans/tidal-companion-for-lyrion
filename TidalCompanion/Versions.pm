package Plugins::TidalCompanion::Versions;

# Versions of an album: the copies in the library (local folders and TIDAL
# albums) with the same artist and title, version information ignored.
#
# One version can be made the default. Playing any other version then plays
# the default instead, and the library view without lossy duplicates hides
# the others. A version only gives way to the default when at least 80% of
# its tracks have a partner there, so a live recording sharing a studio
# album's title is left alone. Without a chosen default the automatic rules
# apply (lossless over lossy, see Library).
#
# A chosen default is remembered by its TIDAL album ID or its folder, which
# survive a rescan; library IDs don't.

use strict;

use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TidalCompanion::Library;
use Plugins::TidalCompanion::Rules qw(albumKey artistKey coversAlbum isLossy matchTracks);

my $log   = logger('plugin.tidalcompanion');
my $prefs = preferences('plugin.tidalcompanion');

my ($groups, $groupOf, %redirects);

my %FORMAT_NAMES = (
	flc => 'FLAC', alc => 'ALAC', mp3 => 'MP3', mp4 => 'AAC', aac => 'AAC',
	ape => 'APE', wvp => 'WavPack', mpc => 'Musepack', ogg => 'Ogg Vorbis',
	ops => 'Opus', wma => 'WMA', aif => 'AIFF', wav => 'WAV', dsf => 'DSD', dff => 'DSD',
);

sub clearCache {
	undef $groups;
	undef $groupOf;
	%redirects = ();
}

sub groupKey {
	my ($artist, $title) = @_;
	return artistKey($artist) . '|' . albumKey($title);
}

# group key => [ version ], each version
# { id, title, year, source => 'local' | 'tidal', formats, tracks, lossy, descriptor }
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
			id => $id, title => $title, year => $year, extid => $extid,
			key => groupKey($artist, $title),
			file => 0, tidal => 0, lossyFiles => 0, types => {},
		};

		if ($url =~ /^tidal:/) {
			$album->{tidal}++;
		}
		else {
			$album->{file}++;
			$album->{lossyFiles}++ if isLossy($type, $lossless);
			$album->{firstUrl} = $url if !$album->{firstUrl} || $url lt $album->{firstUrl};
		}

		$album->{types}->{ $FORMAT_NAMES{lc($type || '')} || uc($type || '?') } = 1;
	}

	my (%result, %of);
	foreach my $album (values %albums) {
		# an album holding both files and TIDAL tracks isn't a version of anything
		next if $album->{file} && $album->{tidal};

		my $source = $album->{tidal} ? 'tidal' : 'local';
		my $descriptor = $source eq 'tidal'
			? ($album->{extid} || '')
			: do { (my $dir = $album->{firstUrl}) =~ s{/[^/]*$}{/}; $dir };

		push @{ $result{ $album->{key} } }, {
			id         => $album->{id},
			title      => $album->{title},
			year       => $album->{year},
			source     => $source,
			formats    => join('/', sort keys %{ $album->{types} }),
			tracks     => $album->{file} + $album->{tidal},
			lossy      => $album->{file} && $album->{lossyFiles} == $album->{file} ? 1 : 0,
			descriptor => $descriptor,
		};
		$of{ $album->{id} } = $album->{key};
	}

	# a steady order: TIDAL first, then local, oldest first
	foreach my $versions (values %result) {
		@$versions = sort {
			($a->{source} eq 'tidal' ? 0 : 1) <=> ($b->{source} eq 'tidal' ? 0 : 1)
			|| ($a->{year} || 0) <=> ($b->{year} || 0)
			|| $a->{id} <=> $b->{id}
		} @$versions;
	}

	$groupOf = \%of;
	return $groups = \%result;
}

# The versions of album $albumId, itself included, and the group key.
sub versionsOf {
	my ($class, $albumId) = @_;

	my $groups = _groups();
	my $key = $groupOf->{$albumId} || return ([], undef);

	return ($groups->{$key} || [], $key);
}

sub _version {
	my ($albumId) = @_;
	my ($versions) = __PACKAGE__->versionsOf($albumId);
	my ($version) = grep { $_->{id} == $albumId } @$versions;
	return $version;
}

# --- the chosen default ----------------------------------------------------------

sub _defaults { $prefs->get('defaultVersions') || {} }

# The ID of the version chosen as default for group $key, if it's in the library.
sub chosenDefault {
	my ($class, $key) = @_;

	my $descriptor = _defaults()->{$key} || return;
	my $versions = _groups()->{$key} || return;

	my ($version) = grep { $_->{descriptor} eq $descriptor } @$versions;
	return $version ? $version->{id} : undef;
}

sub setDefault {
	my ($class, $albumId) = @_;

	my ($versions, $key) = $class->versionsOf($albumId);
	my ($version) = grep { $_->{id} == $albumId } @$versions;
	return 0 unless $key && $version && length $version->{descriptor};

	my $defaults = { %{ _defaults() }, $key => $version->{descriptor} };
	$prefs->set('defaultVersions', $defaults);

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

# --- where an album's tracks play from -----------------------------------------------

sub _playable {
	my ($albumId) = @_;
	return [ grep { $_->{url} =~ /^(?:file|tidal):/ } @{ Plugins::TidalCompanion::Library->tracksOf($albumId) } ];
}

# For album $albumId: { album => ID, tracks => { track ID => track ID } } if its
# tracks play from another version, undef if they play as they are.
sub redirect {
	my ($class, $albumId) = @_;

	return $redirects{$albumId} if exists $redirects{$albumId};

	my $result;
	my (undef, $key) = $class->versionsOf($albumId);
	my $default = $key ? $class->chosenDefault($key) : undef;

	if ($default) {
		if ($default != $albumId) {
			my $own = _playable($albumId);
			my $map = matchTracks($own, _playable($default));
			$result = { album => $default, tracks => $map } if coversAlbum(scalar keys %$map, scalar @$own);
		}
	}
	elsif (Plugins::TidalCompanion::Library->tidalCovers($albumId)) {
		$result = Plugins::TidalCompanion::Library->twinMap($albumId);
	}

	return $redirects{$albumId} = $result;
}

# True if the library view without lossy duplicates leaves album $albumId out.
sub isHidden {
	my ($class, $albumId) = @_;

	my (undef, $key) = $class->versionsOf($albumId);
	my $default = $key ? $class->chosenDefault($key) : undef;

	return $class->redirect($albumId) ? 1 : 0 if $default;

	my $version = _version($albumId) || return 0;
	return 0 unless $version->{source} eq 'local' && $version->{lossy};

	return $class->redirect($albumId)
		|| Plugins::TidalCompanion::Library->localLosslessCopy($albumId) ? 1 : 0;
}

sub hiddenAlbumIds {
	my ($class) = @_;

	return grep { $class->isHidden($_) } map { map { $_->{id} } @$_ } grep { @$_ > 1 } values %{ _groups() };
}

1;
