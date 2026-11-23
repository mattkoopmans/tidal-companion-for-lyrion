package Plugins::TidalCompanion::Library;

# What TIDAL Companion needs to know about the library: which local albums
# are lossy, which TIDAL albums in the library are the same album, and which
# albums each album artist has. Used by the server and by the scanner.

use strict;

use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TidalCompanion::Rules qw(albumKey artistKey isLossy matchTracks);

my $log = logger('plugin.tidalcompanion');

my ($tidalIndex, $artists, %twins);

# Forget everything worked out so far, e.g. after a library scan.
sub clearCache {
	undef $tidalIndex;
	undef $artists;
	%twins = ();
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

			$result = { album => $best, tracks => $bestMap } if $bestMap && %$bestMap;
		}
	}

	return $twins{$albumId} = $result;
}

# 'twin' for a lossy local album that plays from a TIDAL copy, 'lossy' for one
# without, undef for anything else (no local files, or some lossless ones).
sub albumStatus {
	my ($class, $albumId) = @_;

	my @files = grep { $_->{url} =~ /^file:/ } @{ _tracks($albumId) };

	return undef unless @files;
	return undef if grep { !isLossy($_->{content_type}, $_->{lossless}) } @files;

	return %{ $class->twinMap($albumId) } ? 'twin' : 'lossy';
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
