package Plugins::TidalCompanion::Rules;

# The decisions TIDAL Companion makes, kept free of Lyrion so they can be
# tested on their own: what counts as the same album or artist, which files
# are lossy, which TIDAL version of an album to add, and which TIDAL track
# stands in for which local one.

use strict;
use utf8;

use Exporter qw(import);
use Unicode::Normalize qw(NFKD);

our @EXPORT_OK = qw(
	normKey baseTitle albumKey artistKey trackKey
	isLossy isLosslessOnTidal
	groupAlbums pickVersion missingAlbums newAlbums favoriteKeys
	matchTracks similarTitles coversAlbum pickDefaultVersion
);

# Words that mark a release as another version of the same album rather than
# a different album. "Live" is deliberately missing: a live album is a
# different album.
my $VERSION_WORDS = qr/
	remaster | deluxe | edition | expanded | anniversary | bonus | special
	| collector | legacy | reissue | re-issue | mono | stereo | explicit
	| clean | version | hi-?res | 24[-\s]?bit | limited | platinum
	| extended | definitive | redux | director
/xi;

# Lower case, accents dropped, "&" read as "and", a leading "The" dropped and
# everything but letters and digits removed, so "The Sisters Of Mercy" and
# "Sisters of Mercy", or "Mindfunk" and "Mind Funk", come out the same.
sub normKey {
	my ($text) = @_;

	return '' unless defined $text;

	# Lyrion's database hands over UTF-8 bytes, TIDAL's replies decoded text:
	# compare them as text
	my $key = $text;
	utf8::decode($key) unless utf8::is_utf8($key);

	$key = NFKD($key);
	$key =~ s/\p{Mn}//g;
	$key = lc $key;
	$key =~ s/&/ and /g;
	$key =~ s/^\s*the\s+//;
	$key =~ s/[^\p{L}\p{N}]//g;

	return $key;
}

# The title with any version information taken off: bracketed parts such as
# "(2011 Remaster)", "[Deluxe Edition]" or "(1999)", and dash suffixes such
# as " - Remastered 2009". TIDAL keeps some of this in a separate version
# field, which can be passed as the second argument.
sub baseTitle {
	my ($title, $version) = @_;

	$title = '' unless defined $title;
	$title .= " ($version)" if defined $version && $version =~ /\S/;

	# Bracketed parts, innermost first. Version information is removed; other
	# brackets are swapped for markers so they aren't looked at again.
	1 while $title =~ s/\s*[\(\[]([^\(\)\[\]]*)[\)\]]/
		_isVersionText($1) ? '' : " \x{1}$1\x{2}"
	/ex;

	# a trailing " - Remastered 2009" or " – Deluxe Edition"
	while ($title =~ /^(.+?)\s+[-\x{2013}\x{2014}]\s+([^-\x{2013}\x{2014}]+)$/ && _isVersionText($2)) {
		$title = $1;
	}

	$title =~ s/\x{1}/(/g;
	$title =~ s/\x{2}/)/g;
	$title =~ s/\s+/ /g;
	$title =~ s/^\s+|\s+$//g;

	return $title;
}

sub _isVersionText {
	my ($text) = @_;

	# a bonus disc or a second CD is more music, not another version
	return 0 if $text =~ /\b(?:disc|disk|cd)\b/i;

	return $text =~ $VERSION_WORDS || $text =~ /^\s*\d{4}\s*$/ ? 1 : 0;
}

sub albumKey  { normKey(baseTitle(@_)) }
sub artistKey { normKey($_[0]) }
sub trackKey  { normKey(baseTitle($_[0])) }

# True for a local file in a lossy format. Lyrion's lossless flag isn't
# always set (APE files come through with it off), so the format decides.
# Anything not known either way counts as not lossy, so it is left alone.
my %LOSSLESS_TYPES = map { $_ => 1 } qw(flc alc ape wvp wav aif aiff dff dsf pcm wavp);
my %LOSSY_TYPES    = map { $_ => 1 } qw(mp3 mp4 aac m4a ogg ops opus wma mpc mp2);

sub isLossy {
	my ($contentType, $lossless) = @_;

	return 0 if $lossless;

	$contentType = lc($contentType || '');

	return 0 if $LOSSLESS_TYPES{$contentType};
	return $LOSSY_TYPES{$contentType} ? 1 : 0;
}

# True if TIDAL offers the album in CD quality or better. When TIDAL says
# nothing about quality, the album is given the benefit of the doubt.
sub isLosslessOnTidal {
	my ($album) = @_;

	my $tags = ($album->{mediaMetadata} || {})->{tags};
	if ($tags && ref $tags eq 'ARRAY' && @$tags) {
		return (grep { /LOSSLESS/ } @$tags) ? 1 : 0;
	}

	if (my $quality = $album->{audioQuality}) {
		return $quality =~ /LOSSLESS|HI_RES/ ? 1 : 0;
	}

	return 1;
}

# TIDAL albums grouped by album key, leaving out ones not available lossless.
sub groupAlbums {
	my ($albums) = @_;

	my %groups;
	foreach my $album (@{ $albums || [] }) {
		next unless isLosslessOnTidal($album);

		my $key = albumKey($album->{title}, $album->{version});
		next unless length $key;

		push @{ $groups{$key} }, $album;
	}

	return \%groups;
}

# The version to add when TIDAL has several: the one with the most tracks,
# then the most recent release, then the lowest ID so the choice is stable.
sub pickVersion {
	my @albums = @_;

	my ($best) = sort {
		($b->{numberOfTracks} || 0) <=> ($a->{numberOfTracks} || 0)
		|| ($b->{releaseDate} || '') cmp ($a->{releaseDate} || '')
		|| ($a->{id} || 0) <=> ($b->{id} || 0)
	} @albums;

	return $best;
}

# The TIDAL albums whose album key isn't among $libraryKeys (a hash ref), one
# version of each, oldest release first.
sub missingAlbums {
	my ($tidalAlbums, $libraryKeys) = @_;

	my $groups = groupAlbums($tidalAlbums);

	return [ sort {
		($a->{releaseDate} || '') cmp ($b->{releaseDate} || '')
		|| ($a->{title} || '') cmp ($b->{title} || '')
	} map {
		pickVersion(@{ $groups->{$_} })
	} grep {
		!$libraryKeys->{$_}
	} keys %$groups ];
}

# For the library scan: the albums TIDAL lists now that weren't listed last
# time ($seenKeys, a hash ref; undef the first time an artist is checked, in
# which case nothing is new) and aren't in the library. Returns the albums to
# add and every album key TIDAL lists now.
sub newAlbums {
	my ($tidalAlbums, $seenKeys, $libraryKeys) = @_;

	my $groups = groupAlbums($tidalAlbums);
	my @keys = sort keys %$groups;

	return ([], \@keys) unless $seenKeys;

	my @new = map {
		pickVersion(@{ $groups->{$_} })
	} grep {
		!$seenKeys->{$_} && !$libraryKeys->{$_}
	} @keys;

	return (\@new, \@keys);
}

# Album keys of TIDAL favorite albums, by artist: { artist key => { album
# key => 1 } }. An album counts for its main artist and every listed artist.
sub favoriteKeys {
	my ($albums) = @_;

	my %keys;
	foreach my $album (@{ $albums || [] }) {
		next unless ref $album eq 'HASH';

		my $albumKey = albumKey($album->{title}, $album->{version});
		next unless length $albumKey;

		my %artists = map { artistKey($_->{name}) => 1 }
			grep { ref $_ eq 'HASH' && defined $_->{name} }
			($album->{artist}, @{ $album->{artists} || [] });

		$keys{$_}->{$albumKey} = 1 foreach grep { length } keys %artists;
	}

	return \%keys;
}

# Pairs local tracks with TIDAL tracks of the same album. Each track is
# { id, title, disc, tracknum }. Returns { local id => TIDAL id } for the
# tracks that found a partner; each TIDAL track is used once.
sub matchTracks {
	my ($local, $remote) = @_;

	my %byKey;
	foreach my $track (@{ $remote || [] }) {
		my $key = trackKey($track->{title});
		push @{ $byKey{$key} }, $track if length $key;
	}

	my $samePlace = sub {
		my ($x, $y) = @_;
		return ($x->{disc} || 1) == ($y->{disc} || 1)
			&& ($x->{tracknum} || 0) == ($y->{tracknum} || 0);
	};

	my (%map, %used);

	# Same title in the same place, then the same title anywhere, then a
	# nearly identical title (spelling, a title cut short) in the same place.
	foreach my $pass (1, 2, 3) {
		foreach my $track (@{ $local || [] }) {
			next if exists $map{$track->{id}};

			my $key = trackKey($track->{title});

			my ($partner) = $pass < 3
				? grep {
					!$used{$_->{id}} && ($pass == 2 || $samePlace->($_, $track))
				} @{ $byKey{$key} || [] }
				: grep {
					!$used{$_->{id}} && $samePlace->($_, $track)
					&& similarTitles($key, trackKey($_->{title}))
				} @{ $remote || [] };

			next unless $partner;

			$used{$partner->{id}} = 1;
			$map{$track->{id}} = $partner->{id};
		}
	}

	return \%map;
}

# The version of an album to play and show when none was chosen by hand:
# lossless before lossy, then the one with the most tracks, then your own
# files before TIDAL, then the lowest library ID so the choice is stable.
# Each version is { id, lossy, tracks, source }.
sub pickDefaultVersion {
	my @versions = @_;

	my ($best) = sort {
		($a->{lossy} ? 1 : 0) <=> ($b->{lossy} ? 1 : 0)
		|| ($b->{tracks} || 0) <=> ($a->{tracks} || 0)
		|| (($a->{source} || '') eq 'tidal' ? 1 : 0) <=> (($b->{source} || '') eq 'tidal' ? 1 : 0)
		|| ($a->{id} || 0) <=> ($b->{id} || 0)
	} @versions;

	return $best;
}

# True if enough of an album's tracks found partners for the albums to count
# as the same: at least 80%, so a stray extra track doesn't matter but two
# releases that only share a title (a studio album and a live show) don't
# match.
sub coversAlbum {
	my ($matched, $total) = @_;
	return $total && $matched >= 0.8 * $total ? 1 : 0;
}

# True for two track keys that are nearly the same: one starts with the
# other (at least 8 characters), or at most one character in four differs.
sub similarTitles {
	my ($x, $y) = @_;

	return 0 unless length $x && length $y;
	return 1 if $x eq $y;

	my ($short, $long) = length $x < length $y ? ($x, $y) : ($y, $x);
	return 1 if length $short >= 8 && index($long, $short) == 0;

	return _distance($x, $y) <= length($long) / 4 ? 1 : 0;
}

# Levenshtein distance
sub _distance {
	my ($s, $t) = @_;

	my @previous = (0 .. length $t);
	foreach my $i (1 .. length $s) {
		my @current = ($i);
		my $c = substr($s, $i - 1, 1);
		foreach my $j (1 .. length $t) {
			my $cost = $c eq substr($t, $j - 1, 1) ? 0 : 1;
			my $best = $previous[$j - 1] + $cost;
			$best = $previous[$j] + 1 if $previous[$j] + 1 < $best;
			$best = $current[$j - 1] + 1 if $current[$j - 1] + 1 < $best;
			push @current, $best;
		}
		@previous = @current;
	}

	return $previous[-1];
}

1;
