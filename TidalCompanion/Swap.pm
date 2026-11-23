package Plugins::TidalCompanion::Swap;

# Whenever tracks are added to a player's queue, by any route (an album, a
# single track, an artist, a playlist, a mix), lossy local tracks that have a
# lossless Tidal twin in the library are swapped for the Tidal track.

use strict;

use Scalar::Util qw(blessed);

use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TidalCompanion::Hooks qw(wrap);
use Plugins::TidalCompanion::Library;
use Plugins::TidalCompanion::Rules qw(isLossy);

my $log   = logger('plugin.tidalcompanion');
my $prefs = preferences('plugin.tidalcompanion');

sub init {
	# Lyrion calls this by its full name from every place that adds tracks
	wrap('Slim::Player::Playlist::addTracks', \&_addTracks)
		or $log->error("Can't find Slim::Player::Playlist::addTracks; lossy albums won't be swapped for Tidal");
}

sub _addTracks {
	my ($original, $client, $tracksRef, @rest) = @_;

	if ($prefs->get('swapLossy') && ref $tracksRef eq 'ARRAY' && @$tracksRef) {
		my $swapped = eval { swap($tracksRef) };

		if ($@) {
			$log->error("Couldn't swap lossy tracks for Tidal: $@");
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

	main::INFOLOG && $count && $log->is_info && $log->info("Playing $count lossy track(s) from Tidal instead");

	return \@result;
}

# The Tidal track to play instead of $track (a track object or URL), or undef.
sub replacement {
	my ($track) = @_;

	if (!blessed($track)) {
		return unless defined $track && !ref $track && $track =~ /^file:/;
		$track = Slim::Schema->rs('Track')->single({ url => $track }) || return;
	}

	return unless $track->can('url') && $track->can('get_column');
	return unless ($track->url || '') =~ /^file:/;
	return unless isLossy($track->content_type, $track->lossless);

	my $albumId = $track->get_column('album') || return;
	my $twin = Plugins::TidalCompanion::Library->twinMap($albumId);
	my $tidalId = ($twin->{tracks} || {})->{ $track->id } || return;

	return Slim::Schema->find('Track', $tidalId);
}

1;
