package Plugins::TidalCompanion::Views;

# A library view without lossy duplicates: the whole library, minus
#   - each lossy local album that has a lossless TIDAL copy in the library
#   - each lossy local album that has a lossless local copy
#   - lossy tracks in an album that also has the same songs in lossless
# Choose it as a player's library to see only the lossless copy; that album's
# menu says a lossy copy is hidden.
#
# Registered in the server and in the scanner, which rebuilds library views
# at the end of each scan.

use strict;

use Slim::Music::VirtualLibraries;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::TidalCompanion::Library;

use constant ID => 'tidalCompanionNoLossyDuplicates';

my $log = logger('plugin.tidalcompanion');

sub init {
	Slim::Music::VirtualLibraries->registerLibrary({
		id        => ID,
		name      => string('PLUGIN_TIDALCOMPANION_LIBRARY'),
		string    => 'PLUGIN_TIDALCOMPANION_LIBRARY',
		scannerCB => \&_build,
	});
}

sub _build {
	my ($libraryId) = @_;

	my $dbh = Slim::Schema->dbh;

	$dbh->do(q{
		INSERT OR IGNORE INTO library_track (library, track)
		SELECT ?, tracks.id FROM tracks
	}, undef, $libraryId);

	Plugins::TidalCompanion::Library->clearCache;
	my @hidden = Plugins::TidalCompanion::Library->hiddenAlbumIds;

	my $sth = $dbh->prepare_cached(q{
		DELETE FROM library_track
		WHERE library = ? AND track IN (
			SELECT id FROM tracks WHERE album = ? AND url LIKE 'file:%'
		)
	});
	$sth->execute($libraryId, $_) foreach @hidden;

	my @tracks = Plugins::TidalCompanion::Library->hiddenTrackIds;

	$sth = $dbh->prepare_cached('DELETE FROM library_track WHERE library = ? AND track = ?');
	$sth->execute($libraryId, $_) foreach @tracks;

	main::INFOLOG && $log->is_info && $log->info('Library without lossy duplicates hides ' . scalar(@hidden) . ' album(s) and ' . scalar(@tracks) . ' other track(s)');
}

# On the server: build the view if it's empty, or if this version of the
# plugin hasn't built it yet (the rules may have changed).
sub buildIfNeeded {
	my ($class, $version) = @_;

	my $id = Slim::Music::VirtualLibraries->getRealId(ID) || return;
	my $prefs = Slim::Utils::Prefs::preferences('plugin.tidalcompanion');

	my ($count) = Slim::Schema->dbh->selectrow_array(
		'SELECT COUNT(*) FROM library_track WHERE library = ?', undef, $id
	);

	return if $count && ($prefs->get('viewBuiltFor') || '') eq ($version || '');

	main::INFOLOG && $log->is_info && $log->info('Rebuilding the library without lossy duplicates');
	Slim::Music::VirtualLibraries->rebuild(ID);
	$prefs->set('viewBuiltFor', $version || '');
}

1;
