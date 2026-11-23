package Plugins::TidalCompanion::Menus;

# The album and artist context menu items:
#   - on a lossy local album: a note that it plays from TIDAL, or a search for
#     it on TIDAL with an item to add the result to TIDAL favorites
#   - on an artist: the albums TIDAL has that the library doesn't, with an
#     item to add them all to TIDAL favorites

use strict;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::TidalCompanion::Library;
use Plugins::TidalCompanion::Rules qw(albumKey artistKey favoriteKeys missingAlbums groupAlbums);

my $log = logger('plugin.tidalcompanion');

use constant RESCAN_DELAY => 10;

sub init {
	Slim::Menu::AlbumInfo->registerInfoProvider( tidalCompanionAlbum => (
		after => 'top',
		func  => \&albumMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( tidalCompanionArtist => (
		func  => \&artistMenu,
	) );
}

# --- the TIDAL plugin --------------------------------------------------------

sub _tidalReady {
	return Plugins::TIDAL::API::Async->can('new')
		&& Plugins::TIDAL::API->can('getSomeUserId')
		&& Plugins::TIDAL::API->getSomeUserId() ? 1 : 0;
}

sub _api {
	my ($client) = @_;

	return Plugins::TIDAL::Plugin::getAPIHandler($client)
		if ref $client && Plugins::TIDAL::Plugin->can('getAPIHandler');

	return Plugins::TIDAL::API::Async->new({ userId => Plugins::TIDAL::API->getSomeUserId() });
}

sub _cover {
	my ($album) = @_;
	return Plugins::TIDAL::API->getImageUrl($album, 'usePlaceholder');
}

sub _text {
	my ($cb, @lines) = @_;
	$cb->({ items => [ map { { type => 'text', name => $_ } } @lines ] });
}

# --- album menu --------------------------------------------------------------

sub albumMenu {
	my ($client, $url, $album) = @_;

	return unless $album && $album->can('id') && _tidalReady();

	my $status = eval { Plugins::TidalCompanion::Library->albumStatus($album->id) };
	$log->error("Couldn't check album " . $album->id . ": $@") if $@;

	if (!$status) {
		# a TIDAL album standing in for a lossy local copy
		my $copies = eval { Plugins::TidalCompanion::Library->lossyCopiesOf($album->id) } || [];
		return unless @$copies;

		return {
			type => 'text',
			name => cstring($client, 'PLUGIN_TIDALCOMPANION_LOSSY_COPY', $copies->[0]->{formats} || '?'),
		};
	}

	if ($status eq 'twin') {
		return {
			type => 'text',
			name => cstring($client, 'PLUGIN_TIDALCOMPANION_PLAYS_LOSSLESS'),
		};
	}

	return {
		type => 'link',
		name => cstring($client, 'PLUGIN_TIDALCOMPANION_FIND_ON_TIDAL'),
		url  => \&findAlbum,
		passthrough => [{
			artist => Plugins::TidalCompanion::Library->albumArtistName($album->id) || '',
			title  => $album->title,
		}],
	};
}

sub findAlbum {
	my ($client, $cb, $args, $params) = @_;

	my $wantAlbum  = albumKey($params->{title});
	my $wantArtist = artistKey($params->{artist});

	_api($client)->search(sub {
		my $albums = shift;
		$albums = [] unless ref $albums eq 'ARRAY';

		# the same album by the same artist first, then the same artist
		my $score = sub {
			my $album = shift;
			my $sameArtist = grep { artistKey($_->{name}) eq $wantArtist } ($album->{artist} || {}), @{ $album->{artists} || [] };
			return ($sameArtist ? 2 : 0) + (albumKey($album->{title}, $album->{version}) eq $wantAlbum ? 1 : 0);
		};

		my @sorted = map { $_->[1] } sort { $b->[0] <=> $a->[0] } map { [ $score->($_), $_ ] } @$albums;

		return _text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_NOTHING_FOUND')) unless @sorted;

		$cb->({ items => [ map { _albumItem($client, $_) } @sorted ] });
	}, {
		type   => 'albums',
		search => join(' ', grep { $_ } $params->{artist}, $params->{title}),
		limit  => 20,
	});
}

sub _albumTitle {
	my ($album) = @_;
	my $title = $album->{title} || '';
	$title .= " ($album->{version})" if $album->{version} && index($title, $album->{version}) < 0;
	return $title;
}

# A TIDAL album, opening onto an item that adds it to TIDAL favorites.
sub _albumItem {
	my ($client, $album) = @_;

	my $year = substr($album->{releaseDate} || '', 0, 4);
	my $artist = ($album->{artist} || {})->{name} || '';
	my $details = join(' · ', grep { $_ }
		$artist,
		$year,
		$album->{numberOfTracks} ? cstring($client, 'PLUGIN_TIDALCOMPANION_TRACKS', $album->{numberOfTracks}) : '',
	);

	my $title = _albumTitle($album);

	return {
		type  => 'link',
		name  => "$title ($details)",
		line1 => $title,
		line2 => $details,
		image => _cover($album),
		items => [{
			type => 'link',
			name => cstring($client, 'PLUGIN_TIDALCOMPANION_ADD_TO_FAVORITES'),
			url  => \&addAlbums,
			passthrough => [{ albums => [ { id => $album->{id}, title => $title } ] }],
		}],
	};
}

# --- artist menu -------------------------------------------------------------

sub artistMenu {
	my ($client, $url, $artist) = @_;

	return unless $artist && $artist->can('name') && _tidalReady();
	return if Plugins::TidalCompanion::Library->isVariousArtists($artist->id, $artist->name);

	return {
		type => 'link',
		name => cstring($client, 'PLUGIN_TIDALCOMPANION_ADD_MISSING'),
		url  => \&missingForArtist,
		passthrough => [{
			name  => $artist->name,
			extid => $artist->extid,
		}],
	};
}

sub missingForArtist {
	my ($client, $cb, $args, $params) = @_;

	my $name = $params->{name};
	my $libraryArtist = Plugins::TidalCompanion::Library->artist($name) || { albumKeys => {} };
	my $libraryKeys = $libraryArtist->{albumKeys};

	my $tidalId = ($params->{extid} || '') =~ /^tidal:artist:(\d+)$/ ? $1 : $libraryArtist->{tidalId};
	my $api = _api($client);

	my $showMissing;
	my $show = sub {
		my ($albums) = @_;

		# albums already in TIDAL favorites but not yet imported count as present
		$api->getFavorites(sub {
			my $favorites = shift;
			my %present = (%$libraryKeys, %{ favoriteKeys($favorites)->{ artistKey($name) } || {} });
			$showMissing->($albums, \%present);
		}, 'albums', 1);
	};

	$showMissing = sub {
		my ($albums, $present) = @_;

		my $missing = missingAlbums($albums, $present);

		return _text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_NONE_MISSING', $name)) unless @$missing;

		my @all = map { { id => $_->{id}, title => _albumTitle($_) } } @$missing;

		$cb->({ items => [
			{
				type => 'link',
				name => cstring($client, 'PLUGIN_TIDALCOMPANION_ADD_ALL', scalar @$missing),
				url  => \&addAlbums,
				passthrough => [{ albums => \@all }],
			},
			map { _albumItem($client, $_) } @$missing,
		] });
	};

	if ($tidalId) {
		return $api->artistAlbums(sub { $show->(shift) }, $tidalId, 'ALBUMS');
	}

	# Find the artist on TIDAL by name. With several artists of that name, take
	# the first whose albums include one already in the library.
	$api->search(sub {
		my $artists = shift;
		my @candidates = grep { artistKey($_->{name}) eq artistKey($name) } @{ ref $artists eq 'ARRAY' ? $artists : [] };

		return _text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_NO_ARTIST', $name)) unless @candidates;

		my @queue = @candidates[0 .. ($#candidates < 2 ? $#candidates : 2)];
		my $first;

		my $next;
		$next = sub {
			my $candidate = shift @queue;

			return $show->($first || []) unless $candidate;

			$api->artistAlbums(sub {
				my $albums = shift || [];
				$first ||= $albums;

				my $groups = groupAlbums($albums);
				return $show->($albums) if grep { $libraryKeys->{$_} } keys %$groups;

				$next->();
			}, $candidate->{id}, 'ALBUMS');
		};

		$next->();
	}, {
		type   => 'artists',
		search => $name,
		limit  => 10,
	});
}

# --- adding to TIDAL favorites -------------------------------------------------

sub addAlbums {
	my ($client, $cb, $args, $params) = @_;

	my @albums = @{ $params->{albums} || [] };
	return _text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_NOTHING_FOUND')) unless @albums;

	_api($client)->updateFavorite(sub {
		$log->warn('Added to TIDAL favorites: ' . join(', ', map { "$_->{title} ($_->{id})" } @albums));

		my $done = @albums == 1
			? cstring($client, 'PLUGIN_TIDALCOMPANION_ADDED', $albums[0]->{title})
			: cstring($client, 'PLUGIN_TIDALCOMPANION_ADDED_N', scalar @albums);

		my $next = updateLibrarySoon()
			? cstring($client, 'PLUGIN_TIDALCOMPANION_LIBRARY_UPDATING')
			: cstring($client, 'PLUGIN_TIDALCOMPANION_NO_ONLINE_LIBRARY');

		_text($cb, $done, $next);
	}, 'add', 'album', join(',', map { $_->{id} } @albums));
}

# Starts Lyrion's online library update shortly, so a few albums added in a
# row lead to one update. Returns false if online library integration is off.
sub updateLibrarySoon {
	return 0 unless Plugins::TidalCompanion::Library->tidalImportEnabled();

	Slim::Utils::Timers::killTimers(undef, \&_updateLibrary);
	Slim::Utils::Timers::setTimer(undef, time() + RESCAN_DELAY, \&_updateLibrary);

	return 1;
}

sub _updateLibrary {
	if (Slim::Music::Import->stillScanning) {
		Slim::Utils::Timers::setTimer(undef, time() + 60, \&_updateLibrary);
		return;
	}

	main::INFOLOG && $log->is_info && $log->info('Starting the online library update');
	Slim::Control::Request::executeRequest(undef, ['rescan', 'onlinelibrary']);
}

1;
