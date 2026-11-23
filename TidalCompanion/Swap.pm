package Plugins::TidalCompanion::Swap;

# Whenever tracks are added to a player's queue, by any route (an album, a
# single track, an artist, a playlist, a mix), lossy local tracks that have a
# lossless TIDAL twin in the library are swapped for the TIDAL track, and
# tracks of an album with a chosen default version play from that version.

use strict;

use Scalar::Util qw(blessed);

use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TidalCompanion::Hooks qw(wrap);
use Plugins::TidalCompanion::Library;
use Plugins::TidalCompanion::Versions;
use Plugins::TidalCompanion::Rules qw(isLossy);

my $log   = logger('plugin.tidalcompanion');
my $prefs = preferences('plugin.tidalcompanion');

sub init {
	# Lyrion calls this by its full name from every place that adds tracks
	wrap('Slim::Player::Playlist::addTracks', \&_addTracks)
		or $log->error("Can't find Slim::Player::Playlist::addTracks; lossy albums won't be swapped for TIDAL");
}

sub _addTracks {
	my ($original, $client, $tracksRef, @rest) = @_;

	if ($prefs->get('swapLossy') && ref $tracksRef eq 'ARRAY' && @$tracksRef) {
		my $swapped = eval { swap($tracksRef) };

		if ($@) {
			$log->error("Couldn't swap lossy tracks for TIDAL: $@");
		}
		else {
			$tracksRef = $swapped;
		}
	}

	return $original->($client, $tracksRef, @rest);
}

# Returns a new list with the swappable tracks replaced.
sub swap {
	my ($tracks) = @_;

	my $count = 0;

	my @result = map {
		my $replacement = replacement($_);
		$count++ if $replacement;
		$replacement || $_;
	} @$tracks;

	main::INFOLOG && $count && $log->is_info && $log->info("Playing $count lossy track(s) from TIDAL instead");

	return \@result;
}

# Set while a particular version is played on purpose, so it isn't swapped.
our $bypass = 0;

# The track to play instead of $track (a track object or URL): the partner
# on the album's default version, or the lossless TIDAL copy. Undef to play
# $track itself.
sub replacement {
	my ($track) = @_;

	return if $bypass;

	if (!blessed($track)) {
		return unless defined $track && !ref $track && $track =~ /^(?:file|tidal):/;
		$track = Slim::Schema->rs('Track')->single({ url => $track }) || return;
	}

	return unless $track->can('url') && $track->can('get_column');
	return unless ($track->url || '') =~ /^(?:file|tidal):/;

	my $albumId = $track->get_column('album') || return;
	my $redirect = Plugins::TidalCompanion::Versions->redirect($albumId) || return;
	my $otherId = ($redirect->{tracks} || {})->{ $track->id } || return;

	return Slim::Schema->find('Track', $otherId);
}

1;
