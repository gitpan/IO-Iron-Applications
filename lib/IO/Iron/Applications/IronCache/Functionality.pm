package IO::Iron::Applications::IronCache::Functionality;

use 5.010_000;
use strict;
use warnings FATAL => 'all';
use English;

# Global creator
BEGIN {
    # No exports
}

# Global destructor
END {
}

# ABSTRACT: ironcache.pl command internals: functionality.

our $VERSION = '0.10'; # VERSION: generated by DZP::OurPkgVersion

use Log::Any  qw{$log};
use Params::Validate qw(:all);
use Scalar::Util qw(looks_like_number);
use HTTP::Status qw(:constants :is status_message);
use Carp;
use Try::Tiny;
use Scalar::Util qw{blessed looks_like_number};
use Carp::Assert;
use Carp::Assert::More;
use Parallel::Loops;

require IO::Iron::IronCache::Client;
require IO::Iron::IronCache::Cache;
require IO::Iron::IronCache::Item;

use constant {
    OPERATION_PUT => q{put},
    OPERATION_INCREMENT => q{increment},
    OPERATION_DELETE => q{delete},
};


sub list_caches {
    my %params = validate(
        @_, {
            'config' => { type => SCALAR, optional => 1, }, # config file name.
            'policies' => { type => SCALAR, optional => 1, }, # policy file name.
            'no-policy' => { type => BOOLEAN, optional => 1, }, # disable all policy checks.
            'alternatives' => { type => BOOLEAN, optional => 1, }, # only show alternative cache names and item keys.
        }
    );
    $log->tracef('Entering list_caches(%s)', \%params);

    my %cache_params;
    $cache_params{'config'} = $params{'config'} if defined $params{'config'};
    $cache_params{'policies'} = $params{'policies'} if defined $params{'policies'};
    my $client = IO::Iron::IronCache::Client->new(%cache_params);
    my %output = ( 'project_id' => $client->project_id());
    my @caches = $client->get_caches();
    my %infos;
    foreach my $cache (@caches) {
        my %info;
        $info{'name'} = $cache->name();
        $infos{$cache->name()} = \%info;
    }
    $output{'caches'} = \%infos;
    $log->tracef('Exiting list_caches()');
    return %output;
}


sub list_items {
    my %params = validate(
        @_, {
            'config' => { type => SCALAR, optional => 1, }, # config file name.
            'policies' => { type => SCALAR, optional => 1, }, # policy file name.
            'no-policy' => { type => BOOLEAN, optional => 1, }, # disable all policy checks.
            'cache_name' => { type => ARRAYREF, optional => 0, }, # cache name (or string with wildcards?).
            'item_key' => { type => ARRAYREF, optional => 0, }, # item key.
            'alternatives' => { type => BOOLEAN, optional => 1, }, # only show alternative cache names and item keys.
        }
    );
    $log->tracef('Entering list_items(%s)', \%params);

    my %output;
    if($params{'alternatives'}) {
        my $client = _prepare_client(%params);
        if($client->is_item_key_alternatives()) {
            _expand_item_keys('pointer_to_params' => \%params, 'client' => $client);
        }
        else {
            $log->warnf('No limiting policy used. Cannot print alternatives.');
        }
        if($client->is_cache_name_alternatives()) {
            _expand_cache_names('pointer_to_params' => \%params, 'client' => $client);
        }
        else {
            $log->warnf('No limiting policy used. Cannot print alternatives.');
        }
        my %items_and_caches = _prepare_items_and_caches(%params);
        my @sorted_keys = sort { $items_and_caches{$a}->{'order'} <=> $items_and_caches{$b}->{'order'}} keys %items_and_caches;
        foreach my $sorted_key (@sorted_keys) {
            my ($cache_name, $item_key) = split '/', $sorted_key;
            my %result = ( 'error' => 'Not queried');
            $output{'caches'}->{$cache_name}->{'items'}->{$item_key} = \%result;
        }
    }
    else {
        my %results;
        my $client = _prepare_client(%params);
        if($client->is_item_key_alternatives()) {
            _expand_item_keys('pointer_to_params' => \%params, 'client' => $client);
        }
        else {
            $log->warnf('No limiting policy used. Cannot print alternatives.');
        }
        if($client->is_cache_name_alternatives()) {
            _expand_cache_names('pointer_to_params' => \%params, 'client' => $client);
        }
        else {
            $log->warnf('No limiting policy used. Cannot print alternatives.');
        }
        my %items_and_caches = _prepare_items_and_caches(%params);
        $log->debugf('list_items(): items_and_caches=%s', \%items_and_caches);
        my $parallel_exe = Parallel::Loops->new(scalar keys %items_and_caches );
        $parallel_exe->share(\%items_and_caches);
        $parallel_exe->share(\%results);
        my @keys = keys %items_and_caches;
        $log->debugf('list_items(): keys=%s', \@keys);
        my @rval_results = $parallel_exe->foreach(\@keys, sub {
            my $details_to_find_item = $items_and_caches{$_};
            my %result;
            eval {
                %result = _get_item_thread('details_to_find_item' => $details_to_find_item, 'pointer_to_params' => \%params);
            };
            if($EVAL_ERROR) {
                print $EVAL_ERROR;
                return;
            }
            else {
                $results{$_} = \%result;
                return 1;
            }
        });
    
        $log->debugf('list_items(): All parallel loops processed.');
        $log->debugf('list_items(): results=%s', \%results);
        my @sorted_keys = sort { $items_and_caches{$a}->{'order'} <=> $items_and_caches{$b}->{'order'}} keys %items_and_caches;
        foreach my $sorted_key (@sorted_keys) {
            my ($cache_name, $item_key) = split '/', $sorted_key;
            $output{'caches'}->{$cache_name}->{'items'}->{$item_key} = $results{$sorted_key};
        }
    }
    $log->tracef('Exiting list_items():%s', \%output);
    return %output;
}

sub _expand_cache_names {
    my %params = validate_with(
        'params' => \@_, 'spec' => {
            'pointer_to_params' => { type => HASHREF, optional => 0, }, # item key.
            'client' => { type => OBJECT, optional => 0, }, # ref to IronCache client.
        }, 'allow_extra' => 1,
    );
    $log->tracef('Entering _expand_cache_names(%s)', \%params);
    my @alternatives = $params{'client'}->cache_name_alternatives();
    my @valid_alternatives;
    foreach my $alternative (@alternatives) {
        foreach my $candidate (@{$params{'pointer_to_params'}->{'cache_name'}}) {
            if($alternative =~ /^$candidate$/) {
                push @valid_alternatives, $alternative;
            }
        }
    }
    $params{'pointer_to_params'}->{'cache_name'} = \@valid_alternatives;
    $log->tracef('Exiting _expand_cache_names():%s', '[UNDEF]');
    return;
}

sub _expand_item_keys {
    my %params = validate_with(
        'params' => \@_, 'spec' => {
            'pointer_to_params' => { type => HASHREF, optional => 0, }, # item key.
            'client' => { type => OBJECT, optional => 0, }, # ref to IronCache client.
        }, 'allow_extra' => 1,
    );
    $log->tracef('Entering _expand_item_keys(%s)', \%params);
    my @alternatives = $params{'client'}->item_key_alternatives();
    my @valid_alternatives;
    foreach my $alternative (@alternatives) {
        foreach my $candidate (@{$params{'pointer_to_params'}->{'item_key'}}) {
            if($alternative =~ /$candidate/) {
                push @valid_alternatives, $alternative;
            }
        }
    }
    $params{'pointer_to_params'}->{'item_key'} = \@valid_alternatives;
    $log->tracef('Exiting _expand_item_keys():%s', \@valid_alternatives);
    return @valid_alternatives;
}


sub show_cache {
    my %params = validate(
        @_, {
            'config' => { type => SCALAR, optional => 1, }, # config file name.
            'policies' => { type => SCALAR, optional => 1, }, # policy file name.
            'no-policy' => { type => BOOLEAN, optional => 1, }, # disable all policy checks.
            'cache_name' => { type => SCALAR, optional => 0, }, # cache name or names separated with ',' (or string with wildcards?).
        }
    );
    $log->tracef('Entering show_cache(%s)', \%params);

    my %cache_params;
    $cache_params{'config'} = $params{'config'} if defined $params{'config'};
    $cache_params{'policies'} = $params{'policies'} if defined $params{'policies'};
    my $client = IO::Iron::IronCache::Client->new(%cache_params);
    my %output = ( 'project_id' => $client->project_id());
    # TODO Change this to work with wildcards.
    my @cache_names = split q{,}, $params{'cache_name'};
    my @cache_infos;
    foreach my $cache_name (@cache_names) {
        my $cache_info = $client->get_info_about_cache('name' => $cache_name);
        $log->debugf("show_cache(): Fetched info about cache:%s", $cache_info);
        push @cache_infos, $cache_info;
    }
    my %infos;
    foreach my $info (@cache_infos) {
        my %info;
        $info{'name'} = $info->{'name'};
        $info{'id'} = $info->{'id'};
        $info{'project_id'} = $info->{'project_id'};
        $info{'size'} = $info->{'size'};
        $info{'data_size'} = $info->{'data_size'} if defined $info->{'data_size'};
        $info{'created_at'} = $info->{'created_at'} if defined $info->{'created_at'};
        $info{'updated_at'} = $info->{'updated_at'} if defined $info->{'updated_at'};
        $infos{$info->{'name'}} = \%info;
    }
    $output{'caches'} = \%infos;
    $log->tracef('Exiting show_cache()');
    return %output;
}


sub clear_cache {
    my %params = validate(
        @_, {
            'config' => { type => SCALAR, optional => 1, }, # config file name.
            'policies' => { type => SCALAR, optional => 1, }, # policy file name.
            'no-policy' => { type => BOOLEAN, optional => 1, }, # disable all policy checks.
            'cache_name' => { type => ARRAYREF, optional => 0, }, # cache names in array
        }
    );
    $log->tracef('Entering clear_cache(%s)', \%params);

    my %cache_params;
    $cache_params{'config'} = $params{'config'} if defined $params{'config'};
    $cache_params{'policies'} = $params{'policies'} if defined $params{'policies'};
    my $client = IO::Iron::IronCache::Client->new(%cache_params);
    my %output = ( 'project_id' => $client->project_id());
    foreach my $cache_name (@{$params{'cache_name'}}) {
        my $cache = $client->get_cache('name' => $cache_name);
        $cache->clear();
    }
    $log->tracef('Exiting clear_cache()');
    return %output;
}


sub delete_cache {
    my %params = validate(
        @_, {
            'config' => { type => SCALAR, optional => 1, }, # config file name.
            'policies' => { type => SCALAR, optional => 1, }, # policy file name.
            'no-policy' => { type => BOOLEAN, optional => 1, }, # disable all policy checks.
            'cache_name' => { type => ARRAYREF, optional => 0, }, # cache names in array
        }
    );
    $log->tracef('Entering delete_cache(%s)', \%params);

    my %cache_params;
    $cache_params{'config'} = $params{'config'} if defined $params{'config'};
    $cache_params{'policies'} = $params{'policies'} if defined $params{'policies'};
    my $client = IO::Iron::IronCache::Client->new(%cache_params);
    my %output = ( 'project_id' => $client->project_id());
    foreach my $cache_name (@{$params{'cache_name'}}) {
        $client->delete_cache('name' => $cache_name);
    }
    $log->tracef('Exiting _elete_cache()');
    return %output;
}

sub _put_item_thread {
    my %params = validate(
        @_, {
            'item_info' => { type => HASHREF, optional => 0, },
            'pointer_to_params' => { type => HASHREF, optional => 0, }, # item key.
        }
    );
    $log->tracef('Entering _put_item_thread(%s)', \%params);

    my %result;
    my $cache_name = $params{'item_info'}->{'cache_name'};
    my $item_key = $params{'item_info'}->{'item_key'};
    $log->debugf('_put_item_thread():cache_name=%s;item_key=%s;', $cache_name, $item_key);
    my $client = _prepare_client(%{$params{'pointer_to_params'}});
    my $cache = _get_cache_safely('client' => $client, 'cache_name' => $cache_name);
    if (!$cache && $params{'item_info'}->{'create_cache'}) {
        $log->infof('Cache \'%s\' does not exist. Creating new cache.', $cache_name);
        $cache = $client->create_cache('name' => $cache_name);
    }
    if($cache) {
        $log->debugf("put_item(): To item: \'%s\'.'.", $item_key);
        my %item_parameters;
        $item_parameters{'value'} = $params{'item_info'}->{'item_value'};
        $item_parameters{'expires_in'} = $params{'item_info'}->{'expires_in'}
            if $params{'item_info'}->{'expires_in'};
        my $item = IO::Iron::IronCache::Item->new(%item_parameters);
        my $rval = _operate_item_safely('cache' => $cache,
            'item_key' => $item_key, 'operation' => OPERATION_PUT,
            'item' => $item);
        if($rval) {
            # Attn. _operate_item_safely returns undef if alright, otherwise error message.
            $result{'error'} = $rval;
        }
    }
    else {
        $log->warnf('Cache \'%s\' does not exist. Skip item get. (use option --create-cache to insert to a new cache.) ...', $cache_name);
        $result{'error'} = 'Cache not exists.';
    } # if cache else
    return %result;
}


sub put_item {
    my %params = validate(
        @_, {
            'config' => { type => SCALAR, optional => 1, }, # config file name.
            'policies' => { type => SCALAR, optional => 1, }, # policy file name.
            'no-policy' => { type => BOOLEAN, optional => 1, }, # disable all policy checks.
            'cache_name' => { type => ARRAYREF, optional => 0, }, # cache name (or string with wildcards?).
            'item_key' => { type => ARRAYREF, optional => 0, }, # item key.
            'item_value' => { type => SCALAR, optional => 0, }, # item value.
            'create_cache' => { type => BOOLEAN, optional => 1, }, # create cache if cache does not exist.
            'expires_in' => { type => SCALAR, optional => 1, }, # item expires in ? seconds.
        }
    );
    $log->tracef('Entering put_item(%s)', \%params);

    my %output;
    my %results;
    my %items_and_caches = _prepare_items_and_caches(%params);
    $log->debugf('put_item(): items_and_caches=%s', \%items_and_caches);
    my $parallel_exe = Parallel::Loops->new(scalar keys %items_and_caches );
    $parallel_exe->share(\%items_and_caches);
    $parallel_exe->share(\%results);
    my @keys = keys %items_and_caches;
    $log->debugf('put_item(): keys=%s', \@keys);
    my @rval_results = $parallel_exe->foreach(\@keys, sub {
        my $key = $_;
        my $value = $items_and_caches{$key};
        my %result;
        eval {
            %result = _put_item_thread('item_info' => $value, 'pointer_to_params' => \%params);
        };
        if($EVAL_ERROR) {
            print $EVAL_ERROR;
            return;
        }
        else {
            $results{$key} = \%result;
            return 1;
        }
    });

    $log->debugf('put_item(): All parallel loops processed.');
    $log->debugf('put_item(): results=%s', \%results);
    my @sorted_keys = sort { $items_and_caches{$a}->{'order'} <=> $items_and_caches{$b}->{'order'}} keys %items_and_caches;
    foreach my $sorted_key (@sorted_keys) {
        if(exists $results{$sorted_key}->{'error'}) {
            print $results{$sorted_key}->{'error'} . "\n";
        }
    }
    $log->tracef('Exiting put_item():%s', \%output);
    return %output;
}

sub _increment_item_thread {
    my %params = validate(
        @_, {
            'item_info' => { type => HASHREF, optional => 0, },
            'pointer_to_params' => { type => HASHREF, optional => 0, }, # item key.
        }
    );
    $log->tracef('Entering _increment_item_thread(%s)', \%params);

    my %result;
    my $cache_name = $params{'item_info'}->{'cache_name'};
    my $item_key = $params{'item_info'}->{'item_key'};
    $log->debugf('_increment_item_thread():cache_name=%s;item_key=%s;', $cache_name, $item_key);
    my $client = _prepare_client(%{$params{'pointer_to_params'}});
    my $cache = _get_cache_safely('client' => $client, 'cache_name' => $cache_name);
    if (!$cache && $params{'item_info'}->{'create_cache'}) {
        $log->infof('Cache \'%s\' does not exist. Creating new cache.', $cache_name);
        $cache = $client->create_cache('name' => $cache_name);
    }
    if($cache) {
        $log->debugf("_increment_item_thread(): To item: \'%s\'.'.", $item_key);
        my $rval = _operate_item_safely('cache' => $cache,
            'item_key' => $item_key, 'operation' => OPERATION_INCREMENT,
            'increment' =>$params{'item_info'}->{'item_increment'});
        if($rval) {
            # Attn. _operate_item_safely returns undef if alright, otherwise error message.
            $result{'error'} = $rval;
        }
    }
    else {
        $log->warnf('Cache \'%s\' does not exist. Skip item get ...', $cache_name);
        $result{'error'} = 'Cache not exists.';
    }
    return %result;
}


sub increment_item {
    my %params = validate(
        @_, {
            _common_arguments(),
            'cache_name' => { type => ARRAYREF, optional => 0, }, # cache names (can be one).
            'item_key' => { type => ARRAYREF, optional => 0, }, # item keys (can be one).
            'item_increment' => { type => SCALAR, optional => 0, }, # increment item by this value.
            'create_cache' => { type => BOOLEAN, optional => 0, }, # create cache if cache does not exist.
            'create_item' => { type => BOOLEAN, optional => 0, }, # create item if item does not exist.
        }
    );
    $log->tracef('Entering increment_item(%s)', \%params);

    my %output;
    my %results;
    my %items_and_caches = _prepare_items_and_caches(%params);
    $log->debugf('put_item(): items_and_caches=%s', \%items_and_caches);
    my $parallel_exe = Parallel::Loops->new(scalar keys %items_and_caches );
    $parallel_exe->share(\%results);
    my @keys = keys %items_and_caches;
    $log->debugf('put_item(): keys=%s', \@keys);
    my @rval_results = $parallel_exe->foreach(\@keys, sub {
        my $key = $_;
        my $value = $items_and_caches{$key};
        my %result;
        eval {
            %result = _increment_item_thread('item_info' => $value, 'pointer_to_params' => \%params);
        };
        if($EVAL_ERROR) {
            print $EVAL_ERROR;
            return;
        }
        else {
            $results{$key} = \%result;
            return 1;
        }
    });

    $log->debugf('increment_item(): All parallel loops processed.');
    $log->debugf('increment_item(): results=%s', \%results);
    my @sorted_keys = sort { $items_and_caches{$a}->{'order'} <=> $items_and_caches{$b}->{'order'}} keys %items_and_caches;
    foreach my $sorted_key (@sorted_keys) {
        if(exists $results{$sorted_key}->{'error'}) {
            print $results{$sorted_key}->{'error'} . "\n";
        }
    }
    $log->tracef('Exiting increment_item():%s', \%output);
    return %output;
}

sub _get_item_thread {
    my %params = validate(
        @_, {
            'details_to_find_item' => { type => HASHREF, optional => 0, },
            'pointer_to_params' => { type => HASHREF, optional => 0, }, # item key.
        }
    );
    $log->tracef('Entering _get_item_thread(%s)', \%params);

    my %result;
    my $cache_name = $params{'details_to_find_item'}->{'cache_name'};
    my $item_key = $params{'details_to_find_item'}->{'item_key'};
    $log->debugf('_get_item_thread():cache_name=%s;item_key=%s;', $cache_name, $item_key);
    my $client = _prepare_client(%{$params{'pointer_to_params'}});
    my $cache = _get_cache_safely('client' => $client, 'cache_name' => $cache_name);
    if($cache) {
        my $item = _get_item_safely('cache' => $cache, 'item_key' => $item_key);
        if($item) {
            $log->debugf("_get_item_thread(): Finished getting item \'%s\' from cache \'%s\'.", $item_key, $cache_name);
            $result{'value'} = $item->value();
            $result{'cas'} = $item->cas();
            $result{'expires'} = $item->expires() if $item->expires();
        }
        else {
            $log->warnf('Item \'%s\' does not exist in cache \'%s\'.', $item_key, $cache_name);
            $result{'error'} = 'Key not exists.';
        }
    }
    else {
        $log->warnf('Cache \'%s\' does not exist. Skip item get ...', $cache_name);
        $result{'error'} = 'Cache not exists.';
    } # if cache else
    return %result;
}


sub get_item {
    my %params = validate(
        @_, {
            'config' => { type => SCALAR, optional => 1, }, # config file name.
            'policies' => { type => SCALAR, optional => 1, }, # policy file name.
            'no-policy' => { type => BOOLEAN, optional => 1, }, # disable all policy checks.
            'cache_name' => { type => ARRAYREF, optional => 0, }, # cache name (or string with wildcards?).
            'item_key' => { type => ARRAYREF, optional => 0, }, # item key.
        }
    );
    $log->tracef('Entering get_item(%s)', \%params);

    my %output;
    my %results;
    my %items_and_caches = _prepare_items_and_caches(%params);
    $log->debugf('get_item(): items_and_caches=%s', \%items_and_caches);
    my $parallel_exe = Parallel::Loops->new(scalar keys %items_and_caches );
    $parallel_exe->share(\%results);
    my @keys = keys %items_and_caches;
    $log->debugf('get_item(): keys=%s', \@keys);
    my @rval_results = $parallel_exe->foreach(\@keys, sub {
        my $key = $_;
        my $value = $items_and_caches{$key};
        my %result;
        eval {
            %result = _get_item_thread('details_to_find_item' => $value, 'pointer_to_params' => \%params);
        };
        if($EVAL_ERROR) {
            print $EVAL_ERROR;
            return;
        }
        else {
            $results{$key} = \%result;
            return 1;
        }
    });

    $log->debugf('get_item(): All parallel loops processed.');
    $log->debugf('get_item(): results=%s', \%results);
    my @sorted_keys = sort { $items_and_caches{$a}->{'order'} <=> $items_and_caches{$b}->{'order'}} keys %items_and_caches;
    foreach my $sorted_key (@sorted_keys) {
        if(exists $results{$sorted_key}->{'value'}) {
            print $results{$sorted_key}->{'value'} . "\n";
        }
        else {
            print $results{$sorted_key}->{'error'} . "\n";
        }
    }
    $log->tracef('Exiting get_item():%s', \%output);
    return %output;
}

#
# Delete item
#

sub _delete_item_thread {
    my %params = validate(
        @_, {
            'item_info' => { type => HASHREF, optional => 0, },
            'pointer_to_params' => { type => HASHREF, optional => 0, }, # item key.
        }
    );
    $log->tracef('Entering _delete_item_thread(%s)', \%params);

    my %result;
    my $cache_name = $params{'item_info'}->{'cache_name'};
    my $item_key = $params{'item_info'}->{'item_key'};
    $log->debugf('_delete_item_thread():cache_name=%s;item_key=%s;', $cache_name, $item_key);
    my $client = _prepare_client(%{$params{'pointer_to_params'}});
    my $cache = _get_cache_safely('client' => $client, 'cache_name' => $cache_name);
    if($cache) {
        my $rval = _operate_item_safely('cache' => $cache,
            'item_key' => $item_key, 'operation' => OPERATION_DELETE, );
        if($rval) {
            # Attn. _operate_item_safely returns undef if alright, otherwise error message.
            $result{'error'} = $rval;
        }
    }
    else {
        $log->warnf('Cache \'%s\' does not exist. Skip item get ...', $cache_name);
        $result{'error'} = 'Cache not exists.';
    } # if cache else
    return %result;
}


sub delete_item {
    my %params = validate(
        @_, {
            'config' => { type => SCALAR, optional => 1, }, # config file name.
            'policies' => { type => SCALAR, optional => 1, }, # policy file name.
            'no-policy' => { type => BOOLEAN, optional => 1, }, # disable all policy checks.
            'cache_name' => { type => ARRAYREF, optional => 0, }, # cache name (or string with wildcards?).
            'item_key' => { type => ARRAYREF, optional => 0, }, # item key.
        }
    );
    $log->tracef('Entering delete_item(%s)', \%params);

    my %output;
    my %results;
    my %items_and_caches = _prepare_items_and_caches(%params);
    $log->debugf('delete_item(): items_and_caches=%s', \%items_and_caches);
    my $parallel_exe = Parallel::Loops->new(scalar keys %items_and_caches );
    $parallel_exe->share(\%items_and_caches);
    $parallel_exe->share(\%results);
    my @keys = keys %items_and_caches;
    $log->debugf('delete_item(): keys=%s', \@keys);
    my @rval_results = $parallel_exe->foreach(\@keys, sub {
        my $key = $_;
        my $value = $items_and_caches{$key};
        my %result;
        eval {
            %result = _delete_item_thread('item_info' => $value, 'pointer_to_params' => \%params);
        };
        if($EVAL_ERROR) {
            print $EVAL_ERROR;
            return;
        }
        else {
            $results{$key} = \%result;
            return 1;
        }
    });

    $log->debugf('delete_item(): All parallel loops processed.');
    $log->debugf('delete_item(): results=%s', \%results);
    my @sorted_keys = sort { $items_and_caches{$a}->{'order'} <=> $items_and_caches{$b}->{'order'}} keys %items_and_caches;
    foreach my $sorted_key (@sorted_keys) {
        if(exists $results{$sorted_key}->{'error'}) {
            print $results{$sorted_key}->{'error'} . "\n";
        }
    }
    $log->tracef('Exiting delete_item():%s', \%output);
    return %output;
}

### Internals

sub _common_arguments {
    return (
            'config' => { type => SCALAR, optional => 1, }, # config file name.
            'policies' => { type => SCALAR, optional => 1, }, # policy file name.
            'no-policy' => { type => BOOLEAN, optional => 1, }, # disable all policy checks.
    );
}

# Put caches and items in a hash arranged by an ascending number
# in a preparation for processing, possibly threading or forking.
# Return hash:
#%hash = {
#    '!cache_name/item_key!' => { 
#        'cache_name' => '!!', 'item_key' => '!!', 'order' => 1, ('value' => "",)
#    }
#};

# TODO rename cache_name => names, key => keys
sub _prepare_items_and_caches {
    my %params = validate_with(
        'params' => \@_, 'spec' => {
            'cache_name' => { type => ARRAYREF, optional => 0, }, # cache name (or string with wildcards?).
            'item_key' => { type => ARRAYREF, optional => 0, }, # item key.
            'item_value' => { type => SCALAR, optional => 1, }, # item value.
            'create_cache' => { type => BOOLEAN, optional => 1, }, # create cache if cache does not exist.
            'expires_in' => { type => SCALAR, optional => 1, }, # item expires in ? seconds.
            'item_increment' => { type => SCALAR, optional => 1, }, # increment item by this value.
        }, 'allow_extra' => 1,
    );
    my %arranged_order;
    my $counter = 1;
    foreach my $cache_name (@{$params{'cache_name'}}) {
        foreach my $item_key (@{$params{'item_key'}}) {
            my %item = ( 'cache_name' => $cache_name, 'item_key' => $item_key, 'order' => $counter);
            @item{q{item_value},q{create_cache},q{expires_in},q{item_increment}} = 
                    @params{q{item_value},q{create_cache},q{expires_in},q{item_increment}};
            $arranged_order{$cache_name . '/' . $item_key} = \%item;
            $counter++;
        }
    }
    return %arranged_order;   
}

sub _prepare_client {
    my %params = validate_with(
        'params' => \@_, 'spec' => {
            _common_arguments(),
        }, 'allow_extra' => 1,
    );
    my %cache_params;
    $cache_params{'config'} = $params{'config'} if defined $params{'config'};
    $cache_params{'policies'} = $params{'policies'} if defined $params{'policies'};
    return IO::Iron::IronCache::Client->new(%cache_params);
}

# Return undef if cache with given name does not exist.
sub _get_cache_safely {
    my %params = validate(
        @_, {
            'client' => { type => OBJECT, isa => 'IO::Iron::IronCache::Client', optional => 0, }, # client.
            'cache_name' => { type => SCALAR, optional => 0, }, # cache name.
        }
    );
    $log->tracef("'Entering _get_cache_safely(): %s.'.", \%params);

    my $cache;
    try {
        $cache = $params{'client'}->get_cache('name' => $params{'cache_name'});
    }
    catch {
        $log->debugf('_get_cache_safely(): Caught exception:%s', $_);
        croak $_ unless blessed $_ && $_->can('rethrow'); ## no critic (ControlStructures::ProhibitPostfixControls)
        if ( $_->isa('IronHTTPCallException') ) {
            if( $_->status_code == HTTP_NOT_FOUND ) {
                $log->debugf('_get_cache_safely(): Exception: 404 Cache not found.');
                return;
            }
            else {
                $_->rethrow;
            }
        }
        else {
            $_->rethrow;
        }
    }
    finally {
    };

    $log->tracef("'Exiting _get_cache_safely(): %s.'.", $cache);
    return $cache;
}

# Return undef if item with given name does not exist.
sub _get_item_safely {
    my %params = validate(
        @_, {
            'cache' => { type => OBJECT, isa => 'IO::Iron::IronCache::Cache', optional => 0, }, # cache.
            'item_key' => { type => SCALAR, optional => 0, }, # item key.
        }
    );
    $log->tracef("'Entering _get_item_safely(): %s.'.", \%params);

    my $item;
    try {
        $item = $params{'cache'}->get('key' => $params{'item_key'});
    }
    catch {
        $log->debugf('_get_item_safely(): Caught exception:%s', $_);
        croak $_ unless blessed $_ && $_->can('rethrow'); ## no critic (ControlStructures::ProhibitPostfixControls)
        if ( $_->isa('IronHTTPCallException') ) {
            if( $_->status_code == HTTP_NOT_FOUND ) {
                $log->debugf('_get_item_safely(): Exception: 404 Key not found.');
                return;
            }
            else {
                $_->rethrow;
            }
        }
        else {
            $_->rethrow;
        }
    }
    finally {
    };
    $log->tracef("'Exiting _get_item_safely(): %s.'.", $item);
    return $item;
}

# Do put, increment, delete
# Return undef if everything alright. Otherwise error string.
sub _operate_item_safely {
    my %params = validate(
        @_, {
            'cache' => { type => OBJECT, isa => 'IO::Iron::IronCache::Cache', optional => 0, }, # cache.
            'item_key' => { type => SCALAR, optional => 0, },
            'operation' => { type => SCALAR, optional => 0, }, # put|increment|delete
            'item' => { type => OBJECT, isa => 'IO::Iron::IronCache::Item', optional => 1, }, # IO::Iron::IronCache::Item if operation = put.
            'increment' => { type => SCALAR, optional => 1, callbacks => {
                    'Integer check' => sub { return Scalar::Util::looks_like_number(shift); },
                }}, # SCALAR(int) if operation = increment.
        }
    );
    assert(
        ($params{'operation'} eq OPERATION_PUT && $params{'item'} && !$params{'increment'})
        || ($params{'operation'} eq OPERATION_INCREMENT && $params{'increment'} && !$params{'item'})
        || ($params{'operation'} eq OPERATION_DELETE && !$params{'item'} && !$params{'increment'})
        , 'We have the parameters required for the requested operation.');
    $log->tracef("'Entering _operate_item_safely(): %s.'.", \%params);

    try {
        if($params{'operation'} eq OPERATION_PUT) {
            $params{'cache'}->put('key' => $params{'item_key'}, 'item' => $params{'item'});
        }
        elsif($params{'operation'} eq OPERATION_INCREMENT) {
            $params{'cache'}->increment('key' => $params{'item_key'}, 'increment' => $params{'increment'});
        }
        elsif($params{'operation'} eq OPERATION_DELETE) {
            $params{'cache'}->delete('key' => $params{'item_key'});
        }
    }
    catch {
        $log->debugf('_operate_item_safely(): Caught exception:%s', $_);
        croak $_ unless blessed $_ && $_->can('rethrow'); ## no critic (ControlStructures::ProhibitPostfixControls)
        if ( $_->isa('IronHTTPCallException') ) {
            if( $_->status_code == HTTP_NOT_FOUND ) {
                $log->warnf('_operate_item_safely(): Exception: 404 Key not found.');
                # Does can it happen? To delete?
                return 'Key not found.';
            }
            elsif( $_->status_code == HTTP_BAD_REQUEST 
                    && $_->response_message eq 'Cannot increment or decrement non-numeric value'
                ) {
                $log->warnf('_operate_item_safely(): Exception: 400 Item not suitable for incrementation.');
                return 'Item not suitable for incrementation.';
            }
            else {
                $_->rethrow;
            }
        }
        else {
            $_->rethrow;
        }
    }
    finally {
    };
    $log->tracef("'Exiting _operate_item_safely():.'.");
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

IO::Iron::Applications::IronCache::Functionality - ironcache.pl command internals: functionality.

=head1 VERSION

version 0.10

=head2 list_caches

list caches function.

=head2 list_items

list items function.

=head2 show_cache

show cache function.

=head2 clear_cache

Delete all items in a cache.

=head2 delete_cache

delete cache function.

=head2 put_item

put item function.

=head2 increment_item

increment item function.

=head2 get_item

get item function.

=head2 delete_item

delete item function.

=head1 AUTHOR

Mikko Koivunalho <mikko.koivunalho AT iki.fi>

=head1 BUGS

Please report any bugs or feature requests to bug-io-iron-applications@rt.cpan.org or through the web interface at:
 http://rt.cpan.org/Public/Dist/Display.html?Name=IO-Iron-Applications

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Mikko Koivunalho.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

The full text of the license can be found in the
F<LICENSE> file included with this distribution.

=cut
