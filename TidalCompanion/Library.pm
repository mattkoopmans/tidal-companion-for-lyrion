package Plugins::TidalCompanion::Library;

# What TIDAL Companion needs to know about the library: which local albums
# are lossy, which TIDAL albums in the library are the same album, and which
# albums each album artist has. Used by the server and by the scanner.

use strict;

use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TidalCompanion::Rules qw(albumKey artistKey coversAlbum isLossy matchTracks);

my $log = logger('plugin.tidalcompanion');

my ($tidalIndex, $localIndex, $artists, %twins, %localCopies);

# Forget everything worked out so far, e.g. after a library scan.
sub clearCache {
	undef $tidalIndex;
	undef $localIndex;
	undef $artists;
	%twins = ();
	%localCopies = ();
}

sub _dbh { Slim::Schema->dbh }

sub _key {
	my ($artist, $title) = @_;
	return artistKey($artist) . "\0" . albumKey($title);
}

# album key with artist => [ IDs of lossless TIDAL albums in the library ]
sub _tidalIndex {
	return $tidalIndex if $tidalIndex;

	my $rows = _dbh()->selectall_arrayref(q{
		SELECT al.id, al.title, c.name
		FROM albums al
		JOIN contributors c ON c.id = al.contributor
		WHERE EXISTS (
			SELECT 1 FROM tracks t
			WHERE t.album = al.id AND t.url LIKE 'tidal://%' AND t.lossless = 1
		)
	}) || [];

	my %index;
	push @{ $index{ _key($_->[2], $_->[1]) } }, $_->[0] foreach @$rows;

	return $tidalIndex = \%index;
}

# Local albums (with files) by album key with artist:
# { key => [ { id, kind => 'lossy' | 'lossless' | 'mixed', formats } ] }
sub _localIndex {
	return $localIndex if $localIndex;

	my $rows = _dbh()->selectall_arrayref(q{
		SELECT al.id, al.title, c.name, t.content_type, t.lossless
		FROM albums al
		JOIN contributors c ON c.id = al.contributor
		JOIN tracks t ON t.album = al.id
		WHERE t.url LIKE 'file:%' AND t.audio = 1
	}) || [];

	my %albums;
	foreach my $row (@$rows) {
		my ($id, $title, $artist, $type, $lossless) = @$row;

		my $album = $albums{$id} ||= { key => _key($artist, $title), lossy => 0, other => 0, types => {} };
		isLossy($type, $lossless) ? $album->{lossy}++ : $album->{other}++;
		$album->{types}->{ uc($type || '?') } = 1;
	}

	my %index;
	while (my ($id, $album) = each %albums) {
		push @{ $index{ $album->{key} } }, {
			id      => $id,
			kind    => !$album->{other} ? 'lossy' : !$album->{lossy} ? 'lossless' : 'mixed',
			formats => join('/', sort keys %{ $album->{types} }),
		};
	}

	return $localIndex = \%index;
}

# The local album entry for $albumId and the entries sharing its key.
sub _localAlbum {
	my ($albumId) = @_;

	foreach my $albums (values %{ _localIndex() }) {
		foreach (@$albums) {
			return ($_, $albums) if $_->{id} == $albumId;
		}
	}

	return;
}

# A lossless local album that is the same album as lossy local album
# $albumId: same artist and title, and most tracks have a lossless partner.
sub localLosslessCopy {
	my ($class, $albumId) = @_;

	return $localCopies{$albumId} if exists $localCopies{$albumId};

	my $result;
	my ($album, $sameKey) = _localAlbum($albumId);

	if ($album && $album->{kind} eq 'lossy') {
		my @lossy = grep { $_->{url} =~ /^file:/ } @{ _tracks($albumId) };

		foreach my $copy (grep { $_->{kind} eq 'lossless' && $_->{id} != $albumId } @$sameKey) {
			my @lossless = grep { $_->{url} =~ /^file:/ } @{ _tracks($copy->{id}) };
			my $map = matchTracks(\@lossy, \@lossless);

			if (coversAlbum(scalar keys %$map, scalar @lossy)) {
				$result = $copy;
				last;
			}
		}
	}

	return $localCopies{$albumId} = $result;
}

# True if lossy local album $albumId plays (almost) entirely from a TIDAL copy.
sub tidalCovers {
	my ($class, $albumId) = @_;

	my $twin = $class->twinMap($albumId);
	return 0 unless $twin->{tracks};

	return coversAlbum(scalar keys %{ $twin->{tracks} }, $twin->{lossyCount} || 0);
}

sub _tracks {
	my ($albumId) = @_;

	return _dbh()->selectall_arrayref(q{
		SELECT id, title, disc, tracknum, url, content_type, lossless
		FROM tracks
		WHERE album = ? AND audio = 1
	}, { Slice => {} }, $albumId) || [];
}

# For a local album with lossy files and a lossless TIDAL copy in the
# library: { album => TIDAL album ID, tracks => { local track ID => TIDAL
# track ID } }, covering the lossy tracks that have a TIDAL partner. An empty
# hash otherwise.
sub twinMap {
	my ($class, $albumId) = @_;

	return $twins{$albumId} if $twins{$albumId};

	my $result = {};

	my $album = _dbh()->selectrow_arrayref(q{
		SELECT al.title, c.name
		FROM albums al
		JOIN contributors c ON c.id = al.contributor
		WHERE al.id = ?
	}, undef, $albumId);

	if ($album) {
		my @lossy = grep {
			$_->{url} =~ /^file:/ && isLossy($_->{content_type}, $_->{lossless})
		} @{ _tracks($albumId) };

		my @candidates = grep { $_ != $albumId } @{ _tidalIndex()->{ _key($album->[1], $album->[0]) } || [] };

		if (@lossy && @candidates) {
			my ($best, $bestMap);

			foreach my $candidate (@candidates) {
				my @tidal = grep { $_->{url} =~ /^tidal:/ } @{ _tracks($candidate) };
				my $map = matchTracks(\@lossy, \@tidal);

				if (!$bestMap || keys %$map > keys %$bestMap) {
					($best, $bestMap) = ($candidate, $map);
				}
			}

			$result = { album => $best, tracks => $bestMap, lossyCount => scalar @lossy } if $bestMap && %$bestMap;
		}
	}

	return $twins{$albumId} = $result;
}

# For a lossy local album: 'twin' if it plays from a TIDAL copy,
# 'localLossless' if the library has a lossless local copy, 'lossy' if
# neither. Undef for anything else (no local files, or some lossless ones).
sub albumStatus {
	my ($class, $albumId) = @_;

	my @files = grep { $_->{url} =~ /^file:/ } @{ _tracks($albumId) };

	return undef unless @files;
	return undef if grep { !isLossy($_->{content_type}, $_->{lossless}) } @files;

	return 'twin' if $class->tidalCovers($albumId);
	return 'localLossless' if $class->localLosslessCopy($albumId);
	return 'lossy';
}

# Lossy local albums that play from a TIDAL copy or have a lossless local
# copy: the albums the library view without lossy duplicates leaves out.
sub hiddenAlbumIds {
	my ($class) = @_;

	my $tidal = _tidalIndex();
	my @hidden;

	while (my ($key, $albums) = each %{ _localIndex() }) {
		foreach my $album (grep { $_->{kind} eq 'lossy' } @$albums) {
			push @hidden, $album->{id}
				if $class->localLosslessCopy($album->{id})
				|| ($tidal->{$key} && $class->tidalCovers($album->{id}));
		}
	}

	return @hidden;
}

# Lossy tracks in albums that hold both lossy and lossless files, when the
# same album has the song in lossless too (e.g. FLAC and MP3 of every song).
sub hiddenTrackIds {
	my ($class) = @_;

	my @hidden;

	foreach my $album (grep { $_->{kind} eq 'mixed' } map { @$_ } values %{ _localIndex() }) {
		my @files = grep { $_->{url} =~ /^file:/ } @{ _tracks($album->{id}) };

		my @lossy    = grep {  isLossy($_->{content_type}, $_->{lossless}) } @files;
		my @lossless = grep { !isLossy($_->{content_type}, $_->{lossless}) } @files;

		push @hidden, keys %{ matchTracks(\@lossy, \@lossless) };
	}

	return @hidden;
}

# The lossy local albums that album $albumId stands in for: a TIDAL album
# whose tracks play instead of theirs, or a lossless local album.
# Returns [ { id, formats, via => 'tidal' | 'local' } ].
sub lossyCopiesOf {
	my ($class, $albumId) = @_;

	my $album = _dbh()->selectrow_arrayref(q{
		SELECT al.title, c.name FROM albums al JOIN contributors c ON c.id = al.contributor WHERE al.id = ?
	}, undef, $albumId) || return [];

	my $sameKey = _localIndex()->{ _key($album->[1], $album->[0]) } || return [];
	my ($self) = grep { $_->{id} == $albumId } @$sameKey;

	my @copies;
	foreach my $copy (grep { $_->{kind} eq 'lossy' && $_->{id} != $albumId } @$sameKey) {
		if ($self) {
			my $lossless = $class->localLosslessCopy($copy->{id});
			push @copies, { %$copy, via => 'local' } if $lossless && $lossless->{id} == $albumId;
		}
		elsif (($class->twinMap($copy->{id})->{album} || 0) == $albumId && $class->tidalCovers($copy->{id})) {
			push @copies, { %$copy, via => 'tidal' };
		}
	}

	return \@copies;
}

sub albumArtistName {
	my ($class, $albumId) = @_;

	my $row = _dbh()->selectrow_arrayref(q{
		SELECT c.name FROM albums al JOIN contributors c ON c.id = al.contributor WHERE al.id = ?
	}, undef, $albumId);

	return $row ? $row->[0] : undef;
}

sub _variousArtistsId {
	my $va = eval { Slim::Schema->variousArtistsObject };
	return $va ? $va->id : -1;
}

# Every album artist in the library apart from Various Artists, local or from
# an online service: { artist key => { name, tidalId, albumKeys => { album
# key => 1 } } }. Artists whose names only differ in spacing, case, accents
# or a leading "The" are one artist.
sub artists {
	return $artists if $artists;

	my $vaId = _variousArtistsId();

	my $rows = _dbh()->selectall_arrayref(q{
		SELECT al.title, c.id, c.name, c.extid
		FROM albums al
		JOIN contributors c ON c.id = al.contributor
		WHERE al.compilation IS NULL OR al.compilation = 0
	}) || [];

	my %result;
	foreach my $row (@$rows) {
		my ($title, $contributorId, $name, $extid) = @$row;

		next if $contributorId == $vaId;

		my $key = artistKey($name);
		next if !length($key) || $key eq 'variousartists';

		my $artist = $result{$key} ||= { name => $name, albumKeys => {} };
		$artist->{albumKeys}->{ albumKey($title) } = 1;

		if ($extid && $extid =~ /^tidal:artist:(\d+)$/) {
			$artist->{tidalId} ||= $1;
		}
	}

	return $artists = \%result;
}

sub artist {
	my ($class, $name) = @_;
	return $class->artists->{ artistKey($name) };
}

# True if Lyrion's online library integration brings TIDAL favorites into
# the library. Without it, nothing added to TIDAL favorites shows up here.
sub tidalImportEnabled {
	return 0 unless Slim::Music::Import->can('isOnlineLibrarySupportEnabled')
		&& Slim::Music::Import->isOnlineLibrarySupportEnabled();

	return preferences('plugin.onlinelibrary')->get('enable_PLUGIN_TIDAL_NAME') ? 1 : 0;
}

sub isVariousArtists {
	my ($class, $contributorId, $name) = @_;
	return $contributorId == _variousArtistsId() || artistKey($name) eq 'variousartists';
}

1;
