package Plugins::TidalCompanion::TidalSync;

# A small, blocking Tidal client for the library scan, which runs in Lyrion's
# scanner where nothing can wait for callbacks. It borrows the TIDAL plugin's
# account and access token; the TIDAL plugin keeps the token fresh.

use strict;

use JSON::XS qw(decode_json);
use Time::HiRes qw(sleep);
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant BASE_URL  => 'https://api.tidal.com/v1';
use constant PAUSE     => 0.25;   # seconds between requests, to go easy on Tidal
use constant PAGE      => 100;
use constant MAX_ITEMS => 1000;

my $log = logger('plugin.tidalcompanion');

# The Tidal account whose favorites the TIDAL plugin brings into the library
# (the first one, if there are several).
sub account {
	my $tidalPrefs = preferences('plugin.tidal');
	my $accounts = $tidalPrefs->get('accounts') || {};
	my $skip = $tidalPrefs->get('dontImportAccounts') || {};

	my ($userId) = sort grep { !$skip->{$_} } keys %$accounts;

	return $userId;
}

sub new {
	my ($class, $userId) = @_;

	return unless $userId;

	my $token = Slim::Utils::Cache->new->get("tidal_at_$userId") || return;

	my $country = 'US';
	if (eval { require Plugins::TIDAL::API; 1 } && Plugins::TIDAL::API->can('getCountryCode')) {
		$country = Plugins::TIDAL::API->getCountryCode($userId);
	}

	return bless {
		userId  => $userId,
		token   => $token,
		country => $country,
		stopped => 0,
	}, $class;
}

# True once Tidal has refused access or asked us to slow down: the scan
# should stop and try again next time.
sub stopped { $_[0]->{stopped} }

sub _query {
	my (%params) = @_;
	return join('&', map { $_ . '=' . uri_escape_utf8($params{$_}) } sort keys %params);
}

sub _failed {
	my ($self, $what, $response) = @_;

	my $code = $response->code || 0;
	$log->warn("Tidal request failed ($what): $code");

	$self->{stopped} = 1 if $code == 401 || $code == 403 || $code == 429;

	return;
}

# GET with paging; returns the decoded response with every page's items.
sub get {
	my ($self, $path, $params, $maxItems) = @_;

	return if $self->{stopped};

	$maxItems ||= MAX_ITEMS;

	my ($result, @items);
	my $offset = 0;

	while (1) {
		sleep PAUSE;

		my $url = BASE_URL . $path . '?' . _query(
			%{ $params || {} },
			countryCode => $self->{country},
			limit       => PAGE < $maxItems ? PAGE : $maxItems,
			offset      => $offset,
		);

		main::INFOLOG && $log->is_info && $log->info("GET $url");

		my $response = Slim::Networking::SimpleSyncHTTP->new({ timeout => 15 })->get(
			$url, 'Authorization' => 'Bearer ' . $self->{token},
		);

		return $self->_failed($path, $response) unless $response->code == 200;

		$result = eval { decode_json($response->content) };
		if (!$result) {
			$log->warn("Tidal sent something unreadable for $path: $@");
			return;
		}

		last unless ref $result eq 'HASH' && ref $result->{items} eq 'ARRAY';

		push @items, @{ $result->{items} };
		$offset += PAGE;

		last if !@{ $result->{items} }
			|| $offset >= ($result->{totalNumberOfItems} || 0)
			|| $offset >= $maxItems;
	}

	$result->{items} = \@items if ref $result eq 'HASH' && $result->{items};

	return $result;
}

sub searchArtists {
	my ($self, $name) = @_;

	my $result = $self->get('/search/artists', { query => $name }, 10) || return [];
	return $result->{items} || [];
}

# The artist's albums (not EPs, singles or compilations), or undef on failure.
sub artistAlbums {
	my ($self, $artistId) = @_;

	my $result = $self->get("/artists/$artistId/albums", { filter => 'ALBUMS' }) || return;
	return $result->{items} || [];
}

sub addFavoriteAlbums {
	my ($self, @ids) = @_;

	return 0 if $self->{stopped} || !@ids;

	sleep PAUSE;

	my $url = BASE_URL . "/users/$self->{userId}/favorites/albums?" . _query(countryCode => $self->{country});

	my $response = Slim::Networking::SimpleSyncHTTP->new({ timeout => 15 })->post(
		$url,
		'Authorization' => 'Bearer ' . $self->{token},
		'Content-Type'  => 'application/x-www-form-urlencoded',
		_query(albumIds => join(',', @ids), onArtifactNotFound => 'SKIP'),
	);

	return 1 if $response->code =~ /^20\d$/;

	$self->_failed('adding favorites', $response);
	return 0;
}

1;
