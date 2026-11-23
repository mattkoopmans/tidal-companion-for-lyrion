use strict;
use warnings;
use utf8;

use FindBin;
use Test::More;

BEGIN {
	require "$FindBin::Bin/../TidalCompanion/Rules.pm";
	Plugins::TidalCompanion::Rules->import(qw(
		normKey baseTitle albumKey artistKey trackKey
		isLossy isLosslessOnTidal
		groupAlbums pickVersion missingAlbums newAlbums favoriteKeys matchTracks similarTitles
	));
}

binmode Test::More->builder->$_, ':utf8' for qw(output failure_output todo_output);

# --- names --------------------------------------------------------------

is(artistKey('The Sisters Of Mercy'), artistKey('Sisters of Mercy'), 'leading "The" ignored');
is(artistKey('Mindfunk'), artistKey('Mind Funk'), 'spaces ignored');
is(artistKey('Motörhead'), artistKey('Motorhead'), 'accents ignored');
is(artistKey('Simon & Garfunkel'), artistKey('Simon and Garfunkel'), '& read as and');
isnt(artistKey('Stone Temple Pilots'), artistKey('Baroness'), 'different artists differ');
is(normKey(undef), '', 'undef is empty');

# --- version information ------------------------------------------------

my @same = (
	['Fortitude', 'Fortitude'],
	['Vision Thing (2006 Remaster)', 'Vision Thing'],
	['Vision Thing [Deluxe Edition]', 'Vision Thing'],
	['The Better Life - Remastered 2009', 'The Better Life'],
	['The Better Life – Deluxe Edition', 'The Better Life'],
	['Purple (Super Deluxe Edition) [2019 Remaster]', 'Purple'],
	['Night Time (1985)', 'Night Time'],
	['Kings & Thieves (Expanded Edition)', 'Kings and Thieves'],
	['Circle of Snakes (Explicit)', 'Circle of Snakes'],
	['Scream (Collector\'s Edition)', 'Scream'],
	['Dropped (Hi-Res Version)', 'Dropped'],
);
foreach (@same) {
	is(albumKey($_->[0]), albumKey($_->[1]), "\"$_->[0]\" is \"$_->[1]\"");
}

is(albumKey('Vision Thing', 'Remastered'), albumKey('Vision Thing'), 'Tidal version field ignored');

my @different = (
	['Alive (Live)', 'Alive'],
	['Hits (Volume 2)', 'Hits'],
	['Mind Funk', 'Dropped'],
	['Songs: Ohia', 'Songs'],
);
foreach (@different) {
	isnt(albumKey($_->[0]), albumKey($_->[1]), "\"$_->[0]\" is not \"$_->[1]\"");
}

is(baseTitle('Hits (Volume 2) [2011 Remaster]'), 'Hits (Volume 2)', 'other brackets kept');
is(baseTitle('Twenty - One - Remastered'), 'Twenty - One', 'only the version dash part removed');
is(baseTitle('Re-Animator'), 'Re-Animator', 'hyphen inside a word kept');
is(trackKey('Kryptonite - 2008 Remaster'), trackKey('Kryptonite'), 'track version ignored');

# --- lossy files --------------------------------------------------------

ok(isLossy('mp3', 0), 'mp3 is lossy');
ok(isLossy('mp4', 0), 'AAC in mp4 is lossy');
ok(isLossy('mpc', 0), 'Musepack is lossy');
ok(!isLossy('flc', 1), 'FLAC is not lossy');
ok(!isLossy('ape', 0), 'APE is lossless even with the flag off');
ok(!isLossy('alc', 1), 'ALAC is not lossy');
ok(!isLossy('mp4', 1), 'flagged lossless wins');
ok(!isLossy('xyz', 0), 'unknown formats are left alone');
ok(!isLossy(undef, undef), 'nothing known is left alone');

# --- Tidal quality ------------------------------------------------------

ok(isLosslessOnTidal({ mediaMetadata => { tags => ['LOSSLESS'] } }), 'LOSSLESS tag');
ok(isLosslessOnTidal({ mediaMetadata => { tags => ['HIRES_LOSSLESS', 'LOSSLESS'] } }), 'hi-res tag');
ok(!isLosslessOnTidal({ mediaMetadata => { tags => ['DOLBY_ATMOS'] } }), 'Atmos only is not lossless');
ok(isLosslessOnTidal({ audioQuality => 'HI_RES_LOSSLESS' }), 'audioQuality hi-res');
ok(!isLosslessOnTidal({ audioQuality => 'HIGH' }), 'audioQuality HIGH is lossy');
ok(isLosslessOnTidal({}), 'unknown quality allowed');

# --- choosing versions --------------------------------------------------

my $standard = { id => 10, title => 'Fortitude', numberOfTracks => 11, releaseDate => '2021-04-30' };
my $deluxe   = { id => 11, title => 'Fortitude', version => 'Deluxe', numberOfTracks => 13, releaseDate => '2021-04-30' };
my $reissue  = { id => 12, title => 'Fortitude (Remastered)', numberOfTracks => 13, releaseDate => '2023-01-01' };
my $atmos    = { id => 13, title => 'Fortitude', numberOfTracks => 20, mediaMetadata => { tags => ['DOLBY_ATMOS'] } };
my $other    = { id => 20, title => 'Magma', numberOfTracks => 10, releaseDate => '2016-06-17' };
my $older    = { id => 30, title => 'From Mars to Sirius', numberOfTracks => 12, releaseDate => '2005-09-27' };

is(pickVersion($standard, $deluxe)->{id}, 11, 'most tracks wins');
is(pickVersion($standard, $deluxe, $reissue)->{id}, 12, 'then the newest');
is(pickVersion({ id => 5, numberOfTracks => 3 }, { id => 4, numberOfTracks => 3 })->{id}, 4, 'then the lowest ID');

my $groups = groupAlbums([$standard, $deluxe, $reissue, $atmos, $other]);
is_deeply([sort keys %$groups], [sort(albumKey('Fortitude'), albumKey('Magma'))], 'grouped by album');
is(scalar @{ $groups->{albumKey('Fortitude')} }, 3, 'non-lossless version left out');

my $missing = missingAlbums([$standard, $deluxe, $reissue, $other, $older], { albumKey('Magma') => 1 });
is_deeply([map { $_->{id} } @$missing], [30, 12], 'missing albums, one version each, oldest first');

is_deeply(missingAlbums([$standard], { albumKey('Fortitude (Deluxe Edition)') => 1 }), [], 'library version of any edition counts');

# --- new releases -------------------------------------------------------

my ($new, $keys) = newAlbums([$standard, $other], undef, {});
is_deeply($new, [], 'first check adds nothing');
is_deeply($keys, [sort(albumKey('Fortitude'), albumKey('Magma'))], 'first check remembers what is there');

my %seen = map { $_ => 1 } @$keys;
my $fresh = { id => 40, title => 'New One', numberOfTracks => 9, releaseDate => '2026-11-20' };
my $freshDeluxe = { id => 41, title => 'New One (Deluxe)', numberOfTracks => 12, releaseDate => '2026-11-20' };
($new, $keys) = newAlbums([$standard, $other, $fresh, $freshDeluxe, $deluxe], \%seen, {});
is_deeply([map { $_->{id} } @$new], [41], 'new album added once, version with most tracks');
ok((grep { $_ eq albumKey('New One') } @$keys), 'new album remembered');

($new) = newAlbums([$fresh], \%seen, { albumKey('New One') => 1 });
is_deeply($new, [], 'new album already in library is not added');

# --- Tidal favorites ----------------------------------------------------

my $favorites = favoriteKeys([
	{ title => 'New One', version => 'Deluxe', artist => { name => 'Gojira' } },
	{ title => 'Duets', artist => { name => 'The Singer' }, artists => [{ name => 'The Singer' }, { name => 'Guest Star' }] },
	undef,
	{ title => '', artist => { name => 'Nobody' } },
]);
is_deeply($favorites, {
	gojira    => { albumKey('New One') => 1 },
	singer    => { albumKey('Duets') => 1 },
	gueststar => { albumKey('Duets') => 1 },
}, 'favorite albums keyed by every artist, versions ignored');

my %present = (%{ { albumKey('Magma') => 1 } }, %{ $favorites->{gojira} });
($new) = newAlbums([$fresh, $freshDeluxe], \%seen, \%present);
is_deeply($new, [], 'new album already in Tidal favorites but not yet imported is not added');

is_deeply(missingAlbums([$fresh, $other], \%present), [], 'missing list leaves out favorites not yet imported');

# --- tracks -------------------------------------------------------------

my $localTracks = [
	{ id => 1, title => 'Intro',          disc => 1, tracknum => 1 },
	{ id => 2, title => 'Kryptonite',     disc => 1, tracknum => 2 },
	{ id => 3, title => 'Intro',          disc => 2, tracknum => 1 },
	{ id => 4, title => 'Hidden Track',   disc => 1, tracknum => 12 },
];
my $tidalTracks = [
	{ id => 101, title => 'Intro',                      disc => 1, tracknum => 1 },
	{ id => 102, title => 'Kryptonite (2008 Remaster)', disc => 1, tracknum => 3 },
	{ id => 103, title => 'Intro',                      disc => 2, tracknum => 1 },
	{ id => 104, title => 'Bonus Song',                 disc => 2, tracknum => 2 },
];
is_deeply(matchTracks($localTracks, $tidalTracks), { 1 => 101, 2 => 102, 3 => 103 }, 'tracks paired by title, then position');

my $twice = matchTracks(
	[{ id => 1, title => 'Song', disc => 1, tracknum => 5 }, { id => 2, title => 'Song', disc => 1, tracknum => 9 }],
	[{ id => 101, title => 'Song', disc => 1, tracknum => 9 }],
);
is_deeply($twice, { 2 => 101 }, 'a Tidal track is used once, by its own position');

ok(similarTitles(trackKey('Skull Forrest'), trackKey('Skull Forest')), 'one letter off is similar');
ok(similarTitles(trackKey("You Probably Couldn't See for the Lights But You Were Staring Straight"),
	trackKey("You Probably Couldn't See For The Lights But You Were Staring Straight At Me")), 'cut-short title is similar');
ok(similarTitles(trackKey('High Rollah'), trackKey('High Roller')), 'spelling variant is similar');
ok(!similarTitles(trackKey('Judy'), trackKey('Jody Rocks')), 'different songs are not similar');
ok(!similarTitles(trackKey('Intro'), trackKey('Outro')), 'short different titles are not similar');

is_deeply(matchTracks(
	[{ id => 1, title => 'Skull Forrest', disc => undef, tracknum => 5 }, { id => 2, title => 'Wasted', disc => 1, tracknum => 6 }],
	[{ id => 101, title => 'Skull Forest', disc => 1, tracknum => 5 }, { id => 102, title => 'Wasted Years', disc => 1, tracknum => 9 }],
), { 1 => 101 }, 'near titles pair only in the same place');

done_testing();
