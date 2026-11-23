package Plugins::TidalCompanion::Importer;

# A step in Lyrion's library scan, run just before the TIDAL plugin imports
# Tidal favorites: for each album artist in the library, albums that have
# appeared on Tidal since the last check are added to Tidal favorites, so the
# TIDAL import that follows brings them into the library.
#
# The first time an artist is checked, what Tidal has then is only noted;
# filling in an artist's older albums is left to the artist menu item.

use strict;

use File::Spec::Functions qw(catfile);
use JSON::XS;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;

use Plugins::TidalCompanion::Library;
use Plugins::TidalCompanion::Rules qw(albumKey artistKey favoriteKeys groupAlbums newAlbums);
use Plugins::TidalCompanion::TidalSync;

use constant CHECK_EVERY     => 20 * 3600;       # each artist at most this often
use constant RETRY_UNMATCHED => 30 * 86400;      # an artist not found on Tidal
use constant BATCH           => 20;

my $log   = logger('plugin.tidalcompanion');
my $prefs = preferences('plugin.tidalcompanion');

sub initPlugin { if (main::SCANNER) {
	my ($class) = @_;

	# not for a scan of a single folder (same rule as the online library importers)
	return if $ARGV[-1] && 'onlinelibrary' ne $ARGV[-1];

	my $on = $prefs->get('scanNewReleases');
	return if defined $on && !$on;

	return unless Plugins::TidalCompanion::Library->tidalImportEnabled();

	Slim::Music::Import->addImporter($class, {
		type              => 'file',
		weight            => 190,   # after local files (1), before TIDAL (200)
		use               => 1,
		onlineLibraryOnly => 1,
	});

	return 1;
} }

sub startScan { if (main::SCANNER) {
	my ($class) = @_;

	eval { $class->run };
	$log->error("Checking for new releases on Tidal failed: $@") if $@;

	Slim::Music::Import->endImporter($class);
} }

sub _stateFile {
	return catfile(preferences('server')->get('cachedir'), 'tidalcompanion.json');
}

sub _loadState {
	my $file = _stateFile();
	return {} unless -e $file;

	open(my $fh, '<', $file) or return {};
	local $/;
	my $state = eval { decode_json(<$fh>) };
	close $fh;

	return ref $state eq 'HASH' ? $state : {};
}

sub _saveState {
	my ($state) = @_;

	my $file = _stateFile();
	my $temp = "$file.tmp";

	if (open(my $fh, '>', $temp)) {
		print $fh JSON::XS->new->canonical->encode($state);
		close $fh;
		rename($temp, $file) or $log->error("Couldn't save $file: $!");
	}
	else {
		$log->error("Couldn't save $temp: $!");
	}
}

# The Tidal artist and their albums, or nothing if the artist can't be found.
# An artist found by name is only accepted if Tidal lists at least one album
# that is already in the library, so a namesake isn't mistaken for them.
sub _findArtist {
	my ($tidal, $artist, $state) = @_;

	if (my $id = $artist->{tidalId} || $state->{id}) {
		my $albums = $tidal->artistAlbums($id);
		return ($id, $albums) if $albums;
		return;
	}

	my @candidates = grep { artistKey($_->{name}) eq artistKey($artist->{name}) } @{ $tidal->searchArtists($artist->{name}) };

	foreach my $candidate (@candidates[0 .. ($#candidates < 2 ? $#candidates : 2)]) {
		my $albums = $tidal->artistAlbums($candidate->{id}) || next;
		my $groups = groupAlbums($albums);

		return ($candidate->{id}, $albums) if grep { $artist->{albumKeys}->{$_} } keys %$groups;
	}

	return;
}

sub run {
	my ($class) = @_;

	my $userId = Plugins::TidalCompanion::TidalSync->account;
	if (!$userId) {
		main::INFOLOG && $log->is_info && $log->info('No Tidal account; not checking for new releases');
		return;
	}

	my $tidal = Plugins::TidalCompanion::TidalSync->new($userId);
	if (!$tidal) {
		$log->warn('No Tidal access yet; not checking for new releases this time');
		return;
	}

	# Albums already in Tidal favorites count as in the library: they may not
	# have been imported yet (favorited since the last import, or a scan that
	# clears the library first, which removes Tidal albums until TIDAL's import
	# runs after this step).
	my $favorites = $tidal->favoriteAlbums;
	if (!$favorites) {
		$log->warn("Couldn't read your Tidal favorites; not checking for new releases this time");
		return;
	}
	my $favoriteKeys = favoriteKeys($favorites);

	Plugins::TidalCompanion::Library->clearCache;
	my $artists = Plugins::TidalCompanion::Library->artists;
	my @keys = sort keys %$artists;

	my $state = _loadState();
	my $known = $state->{artists} ||= {};

	my $progress = Slim::Utils::Progress->new({
		type  => 'importer',
		name  => 'plugin_tidalcompanion_scan',
		total => scalar @keys,
		every => 1,
	});

	my $now = time();
	my ($checked, @toAdd, %adding) = (0);

	foreach my $key (@keys) {
		my $artist = $artists->{$key};
		$progress->update($artist->{name});

		my $artistState = $known->{$key} ||= {};

		next if $artistState->{checked} && $now - $artistState->{checked} < CHECK_EVERY;
		next if $artistState->{retryAfter} && $now < $artistState->{retryAfter};

		my ($id, $albums) = _findArtist($tidal, $artist, $artistState);

		last if $tidal->stopped;

		if (!$id) {
			$artistState->{retryAfter} = $now + RETRY_UNMATCHED;
			next;
		}

		$checked++;
		delete $artistState->{retryAfter};
		$artistState->{id} = $id;
		$artistState->{checked} = $now;

		my $seen = $artistState->{seen} ? { map { $_ => 1 } @{ $artistState->{seen} } } : undef;
		my %present = (%{ $artist->{albumKeys} }, %{ $favoriteKeys->{$key} || {} });
		my ($new, $current) = newAlbums($albums, $seen, \%present);

		# an album shared by two library artists is added once
		$new = [ grep { !$adding{ $_->{id} }++ } @$new ];

		# new albums are only noted as seen once they've been added
		my %newKeys = map { albumKey($_->{title}, $_->{version}) => 1 } @$new;
		my %all = map { $_ => 1 } @{ $artistState->{seen} || [] }, grep { !$newKeys{$_} } @$current;
		$artistState->{seen} = [ sort keys %all ];

		push @toAdd, map { { album => $_, artistKey => $key, artist => $artist->{name} } } @$new;
	}

	my $added = 0;
	while (my @batch = splice(@toAdd, 0, BATCH)) {
		if ($tidal->addFavoriteAlbums(map { $_->{album}->{id} } @batch)) {
			foreach (@batch) {
				my $album = $_->{album};
				push @{ $known->{ $_->{artistKey} }->{seen} }, albumKey($album->{title}, $album->{version});
				$log->warn("New release added to Tidal favorites: $_->{artist} - $album->{title} ($album->{id})");
				$added++;
			}
		}
		else {
			$log->warn('Could not add to Tidal favorites: ' . join(', ', map { "$_->{artist} - $_->{album}->{title}" } @batch));
		}
	}

	$log->warn('Stopped checking for new releases early; Tidal refused or asked to slow down. Carrying on next scan.') if $tidal->stopped;

	main::INFOLOG && $log->is_info && $log->info("Checked $checked artist(s) on Tidal, added $added new release(s)");

	_saveState($state);
	$progress->final;
}

1;
