package Plugins::TidalCompanion::Menus;

# The album and artist context menu items:
#   - on an album: a note if it plays as another version or is hidden, and
#     its versions in the library, with an item to make one the default;
#     without other versions, a search for it on TIDAL
#   - on an artist: the albums TIDAL has that the library doesn't, with an
#     item to add them all to TIDAL favorites

use strict;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::TidalCompanion::Library;
use Plugins::TidalCompanion::Versions;
use Plugins::TidalCompanion::Views;
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

	return unless $album && $album->can('id');

	my $id = $album->id;
	my ($versions, $key) = eval { Plugins::TidalCompanion::Versions->versionsOf($id) };
	$log->error("Couldn't look up versions of album $id: $@") if $@;
	$versions ||= [];

	my ($self) = grep { $_->{id} == $id } @$versions;
	my @items;

	if (my $note = eval { _statusNote($client, $id, $versions, $key) }) {
		push @items, $note;
	}

	if (@$versions > 1) {
		push @items, {
			type => 'link',
			name => cstring($client, 'PLUGIN_TIDALCOMPANION_VERSIONS', scalar @$versions),
			url  => \&versionsMenu,
			passthrough => [{ albumId => $id }],
		};
	}

	if ($self) {
		push @items, {
			type => 'link',
			name => cstring($client, 'PLUGIN_TIDALCOMPANION_MERGE'),
			url  => \&mergeMenu,
			passthrough => [{ albumId => $id }],
		};

		push @items, {
			type => 'link',
			name => cstring($client, 'PLUGIN_TIDALCOMPANION_REJOIN'),
			url  => \&groupChange,
			passthrough => [{ action => 'rejoin', albumId => $id }],
		} if Plugins::TidalCompanion::Versions->isSeparated($id);
	}
	elsif (_tidalReady()) {
		my $lossy = $self && $self->{source} eq 'local' && $self->{lossy};

		push @items, {
			type => 'link',
			name => cstring($client, $lossy ? 'PLUGIN_TIDALCOMPANION_FIND_ON_TIDAL' : 'PLUGIN_TIDALCOMPANION_OTHER_ON_TIDAL'),
			url  => $lossy ? \&findAlbum : \&moreOnTidal,
			passthrough => [{
				artist => Plugins::TidalCompanion::Library->albumArtistName($id) || '',
				title  => $album->title,
			}],
		};
	}

	return \@items;
}

sub _describe {
	my ($client, $version) = @_;
	return $version->{source} eq 'tidal' ? "TIDAL $version->{formats}" : $version->{formats};
}

# A line saying whether this album plays as another version or is hidden.
sub _statusNote {
	my ($client, $id, $versions, $key) = @_;

	if (my $redirect = Plugins::TidalCompanion::Versions->redirect($id)) {
		my ($target) = grep { $_->{id} == $redirect->{album} } @$versions;
		return {
			type => 'text',
			name => cstring($client, 'PLUGIN_TIDALCOMPANION_PLAYS_AS', $target ? _describe($client, $target) : '?'),
		};
	}

	my $default = $key ? Plugins::TidalCompanion::Versions->chosenDefault($key) : undef;
	return { type => 'text', name => cstring($client, 'PLUGIN_TIDALCOMPANION_IS_DEFAULT') }
		if $default && $default == $id;

	return;
}

sub versionsMenu {
	my ($client, $cb, $args, $params) = @_;

	my $albumId = $params->{albumId};
	my ($versions, $key) = Plugins::TidalCompanion::Versions->versionsOf($albumId);
	my $default = $key ? Plugins::TidalCompanion::Versions->chosenDefault($key) : undef;
	my $automatic = $key ? Plugins::TidalCompanion::Versions->defaultOf($key) : undef;

	my @items;
	foreach my $version (@$versions) {
		my $id = $version->{id};

		my @flags;
		push @flags, cstring($client, $default ? 'PLUGIN_TIDALCOMPANION_FLAG_DEFAULT' : 'PLUGIN_TIDALCOMPANION_FLAG_AUTO_DEFAULT') if $automatic && $automatic == $id;
		push @flags, cstring($client, 'PLUGIN_TIDALCOMPANION_FLAG_THIS') if $id == $albumId;
		push @flags, cstring($client, 'PLUGIN_TIDALCOMPANION_FLAG_HIDDEN') if Plugins::TidalCompanion::Versions->isHidden($id);
		push @flags, cstring($client, 'PLUGIN_TIDALCOMPANION_FLAG_MERGED') if Plugins::TidalCompanion::Versions->isMerged($id);

		my $details = join(' · ', grep { $_ }
			_describe($client, $version),
			cstring($client, 'PLUGIN_TIDALCOMPANION_TRACKS', $version->{tracks}),
			$version->{year},
			@flags,
		);

		push @items, {
			type  => 'link',
			name  => "$version->{title} ($details)",
			line1 => $version->{title},
			line2 => $details,
			items => [
				{
					type => 'playlist',
					name => cstring($client, 'PLUGIN_TIDALCOMPANION_SHOW_TRACKS'),
					url  => \&Slim::Menu::BrowseLibrary::_tracks,
					passthrough => [{ searchTags => [ "album_id:$id", 'library_id:-1' ] }],
				},
				{
					type => 'link',
					name => cstring($client, 'PLUGIN_TIDALCOMPANION_PLAY_VERSION'),
					url  => \&playVersion,
					passthrough => [{ albumId => $id }],
				},
				Plugins::TidalCompanion::Versions->isMerged($id)
					? {
						type => 'link',
						name => cstring($client, 'PLUGIN_TIDALCOMPANION_UNDO_MERGE'),
						url  => \&groupChange,
						passthrough => [{ action => 'separate', albumId => $id }],
					}
					: {
						type => 'link',
						name => cstring($client, 'PLUGIN_TIDALCOMPANION_SEPARATE'),
						url  => \&groupChange,
						passthrough => [{ action => 'separate', albumId => $id }],
					},
				$default && $default == $id
					? { type => 'text', name => cstring($client, 'PLUGIN_TIDALCOMPANION_IS_DEFAULT') }
					: {
						type => 'link',
						name => cstring($client, 'PLUGIN_TIDALCOMPANION_MAKE_DEFAULT'),
						url  => \&makeDefault,
						passthrough => [{ albumId => $id, label => "$version->{title} (" . _describe($client, $version) . ')' }],
					},
			],
		};
	}

	push @items, {
		type => 'link',
		name => cstring($client, 'PLUGIN_TIDALCOMPANION_AUTOMATIC'),
		url  => \&automaticChoice,
		passthrough => [{ key => $key }],
	} if $default;

	push @items, {
		type => 'link',
		name => cstring($client, 'PLUGIN_TIDALCOMPANION_MORE_ON_TIDAL'),
		url  => \&moreOnTidal,
		passthrough => [{
			artist => Plugins::TidalCompanion::Library->albumArtistName($albumId) || '',
			title  => $versions->[0] ? $versions->[0]->{title} : '',
		}],
	} if _tidalReady();

	$cb->({ items => \@items });
}

sub playVersion {
	my ($client, $cb, $args, $params) = @_;

	return _text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_NO_PLAYER')) unless ref $client;

	{
		# this version on purpose, not the default
		local $Plugins::TidalCompanion::Swap::bypass = 1;
		$client->execute(['playlistcontrol', 'cmd:load', "album_id:$params->{albumId}", 'library_id:-1']);
	}

	_text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_PLAYING_VERSION'));
}

sub makeDefault {
	my ($client, $cb, $args, $params) = @_;

	Plugins::TidalCompanion::Versions->setDefault($params->{albumId})
		or return _text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_CANT_DEFAULT'));

	$log->warn("Default version chosen: $params->{label}");
	Plugins::TidalCompanion::Views->rebuild;

	_text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_DEFAULT_SET', $params->{label}));
}

sub automaticChoice {
	my ($client, $cb, $args, $params) = @_;

	Plugins::TidalCompanion::Versions->clearDefault($params->{key}) if $params->{key};
	Plugins::TidalCompanion::Views->rebuild;

	_text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_AUTOMATIC_SET'));
}

# Albums this album can be merged with, each opening onto a confirmation.
sub mergeMenu {
	my ($client, $cb, $args, $params) = @_;

	my $albumId = $params->{albumId};
	my $candidates = Plugins::TidalCompanion::Versions->mergeCandidates($albumId);

	return _text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_NOTHING_TO_MERGE')) unless @$candidates;

	$cb->({ items => [ map {
		my $candidate = $_;
		my $details = join(' · ', grep { $_ }
			$candidate->{artist},
			$candidate->{count} > 1 ? cstring($client, 'PLUGIN_TIDALCOMPANION_N_VERSIONS', $candidate->{count}) : '',
		);

		{
			type  => 'link',
			name  => "$candidate->{title} ($details)",
			line1 => $candidate->{title},
			line2 => $details,
			items => [{
				type => 'link',
				name => cstring($client, 'PLUGIN_TIDALCOMPANION_MERGE_CONFIRM', $candidate->{title}),
				url  => \&groupChange,
				passthrough => [{ action => 'merge', albumId => $albumId, targetId => $candidate->{id} }],
			}],
		}
	} @$candidates ] });
}

# Merges, separates or puts back an album, then rebuilds the library view.
sub groupChange {
	my ($client, $cb, $args, $params) = @_;

	my $versions = 'Plugins::TidalCompanion::Versions';
	my $version = $versions->version($params->{albumId});
	my $title = $version ? $version->{title} : '?';

	my ($ok, $message);
	if ($params->{action} eq 'merge') {
		$ok = $versions->merge($params->{albumId}, $params->{targetId});
		$message = 'PLUGIN_TIDALCOMPANION_MERGED';
	}
	elsif ($params->{action} eq 'separate') {
		my $wasMerged = $versions->isMerged($params->{albumId});
		$ok = $versions->separate($params->{albumId});
		$message = $wasMerged ? 'PLUGIN_TIDALCOMPANION_MERGE_UNDONE' : 'PLUGIN_TIDALCOMPANION_SEPARATED';
	}
	elsif ($params->{action} eq 'rejoin') {
		$ok = $versions->rejoin($params->{albumId});
		$message = 'PLUGIN_TIDALCOMPANION_REJOINED';
	}

	return _text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_CANT_CHANGE')) unless $ok;

	$log->warn("Versions changed ($params->{action}): $title");
	Plugins::TidalCompanion::Views->rebuild;

	_text($cb, cstring($client, $message, $title));
}

# Versions of the album on TIDAL that aren't in the library yet.
sub moreOnTidal {
	my ($client, $cb, $args, $params) = @_;

	my $wantAlbum  = albumKey($params->{title});
	my $wantArtist = artistKey($params->{artist});

	my %inLibrary = map { $_ => 1 } Plugins::TidalCompanion::Library->tidalAlbumIdsInLibrary;

	_api($client)->search(sub {
		my $albums = shift;
		$albums = [] unless ref $albums eq 'ARRAY';

		my @matches = grep {
			my $album = $_;
			!$inLibrary{ $album->{id} }
			&& albumKey($album->{title}, $album->{version}) eq $wantAlbum
			&& grep { artistKey($_->{name}) eq $wantArtist } ($album->{artist} || {}), @{ $album->{artists} || [] }
		} @$albums;

		return _text($cb, cstring($client, 'PLUGIN_TIDALCOMPANION_NO_OTHER_ON_TIDAL')) unless @matches;

		$cb->({ items => [ map { _albumItem($client, $_) } @matches ] });
	}, {
		type   => 'albums',
		search => join(' ', grep { $_ } $params->{artist}, $params->{title}),
		limit  => 50,
	});
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
