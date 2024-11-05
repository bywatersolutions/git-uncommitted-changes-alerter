#!/usr/bin/perl

use feature 'say';

use Modern::Perl;

use Data::Dumper;
use HTTP::Request;
use JSON;
use LWP::UserAgent;
use Term::ANSIColor;

my $webhook_url          = $ENV{DEVOPS_SLACK_WEBHOOK_URL}    || undef;
my $git_directory        = $ENV{DEVOPS_GIT_DIRECTORY}        || q{.};
my $threshold_in_minutes = $ENV{DEVOPS_THRESHOLD_IN_MINUTES} || 10;
my $debug                = $ENV{DEVOPS_DEBUG}                || 0;

say "Debug level set to $debug" if $debug;

say "Changing directory to: $git_directory";
chdir($git_directory) or die "Couldn't go inside $git_directory directory, $!";

my $threshold_in_seconds = $threshold_in_minutes * 60;

print "Gathing files to check...." if $debug > 0;
my $cmd =
q/for file in $(git ls-files --others --modified --exclude-standard); do stat --format '%Y_-_-_-_%n' "$file"; done/;
my @lines = qx/$cmd/;
say "done!" if $debug > 0;

my $current_time = time;

my @files;
foreach my $line (@lines) {
    chomp $line;
    my ( $epoch_time, $filename ) = split( '_-_-_-_', $line );
    say "Checking file $filename..." if $debug > 1;

    next if $filename =~ /swp$/;
    next if $filename =~ /^\./;

    my $age_in_seconds = $current_time - $epoch_time;
    if ( $age_in_seconds > $threshold_in_seconds ) {
        print color('red');
        say
          "File $filename surpasses threshhold of $threshold_in_seconds seconds"
          if $debug > 0;
        print color('reset');
        my $age_in_minutes = $age_in_seconds / 60;
        my $formatted_minutes = sprintf( "%.2f", $age_in_minutes );
        push(
            @files,
            {
                filename                 => $filename,
                age_in_seconds           => $age_in_seconds,
                age_in_minutes           => $age_in_minutes,
                age_in_minutes_formatted => $formatted_minutes,
            }
        );
    }
}

if (@files) {
    if ( $debug > 0 ) {
        print color('bold red');
        say
          "Found ${\( scalar @files )} uncommitted files or files with changes";
        print color('reset');
    }
}
else {
    if ( $debug > 0 ) {
        print color('green');
        say "No uncomotted changes found!";
    }
    exit 0;
}

my $files_count = scalar @files;
say "Found $files_count files over the threshold" if $debug > 0;
my $exceeded_threshold = $files_count > 25;
say "Exceeded threshold: $exceeded_threshold";

# Slack can't handle json payloads over some size so only print the first 25 files
splice( @files, 25 );

if ($webhook_url) {
    my $payload = {
        text =>
"The following files have uncommitted changes over $threshold_in_minutes minutes old!",
        blocks => [
            {
                type => "section",
                text => {
                    type => "mrkdwn",
                    text =>
"The following files have uncommitted changes over $threshold_in_minutes minutes old!",
                }
            },
            { type => "divider" },

            # Build a list of files to send to slack
            map {
                {
                    type   => "section",
                    fields => [
                        { type => "mrkdwn", text => "*$_->{filename}*" },
                        {
                            type => "plain_text",
                            text => "$_->{age_in_minutes_formatted} minutes"
                        }
                    ]
                }
            } @files,
        ]
    };

    if ($exceeded_threshold) {
        push(
            @{ $payload->{blocks} },
            {
                type   => "section",
                fields => [
                    { type => "mrkdwn", text => "*_and more!_*" },
                    {
                        type => "plain_text",
                        text => "and more!"
                    }
                ]
            }
        );
    }

    say "Payload: " . Data::Dumper::Dumper($payload) if $debug > 2;

    my $ua = LWP::UserAgent->new;

    my $req = HTTP::Request->new( POST => $webhook_url );
    $req->header( 'Content-Type' => 'application/json' );

    my $json_payload = encode_json($payload);
    say "JSON payload: $json_payload" if $debug > 3;
    $req->content($json_payload);

    my $response = $ua->request($req);

    # Check for a successful response
    unless ( $response->is_success ) {
        die "Failed to send message: " . $response->status_line . "\n";
    }
}
