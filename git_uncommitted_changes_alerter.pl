#!/usr/bin/perl

use Modern::Perl;

use Data::Dumper;
use LWP::UserAgent;
use HTTP::Request;
use JSON;

my $webhook_url          = $ENV{DEVOPS_SLACK_WEBHOOK_URL}    || die "No ENV for DEVOPS_SLACK_WEBHOOK_URL set!";
my $git_directory        = $ENV{DEVOPS_GIT_DIRECTORY}        || "No ENV for DEVOPS_GIT_DIRECTORY set!";
my $threshold_in_minutes = $ENV{DEVOPS_THRESHOLD_IN_MINUTES} || 10;

my $threshold_in_seconds = $threshold_in_minutes * 60;

my $cmd =
    q/for file in $(git ls-files --others --modified --exclude-standard); do stat --format '%Y_-_-_-_%n' "$file"; done/;
my @lines = qx/$cmd/;

my $current_time = time;

my @files;
foreach my $line (@lines) {
    chomp $line;
    my ( $epoch_time, $filename ) = split( '_-_-_-_', $line );

    next if $filename =~ /swp$/;

    my $age_in_seconds = $current_time - $epoch_time;
    if ( $age_in_seconds > $threshold_in_seconds ) {
        my $age_in_minutes    = $age_in_seconds / 60;
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

exit 0 unless @files;

my $payload = {
    text   => "The following files have uncommitted changes over $threshold_in_minutes minutes old!",
    blocks => [
        {
            type => "section",
            text => {
                type => "mrkdwn",
                text => "The following files have uncommitted changes over $threshold_in_minutes minutes old!",
            }
        },
        { type => "divider" },
        map {
            {
                type   => "section",
                fields => [
                    { type => "mrkdwn",     text => "*$_->{filename}*" },
                    { type => "plain_text", text => "$_->{age_in_minutes_formatted} minutes" }
                ]
            }
        } @files,
    ]
};

my $ua = LWP::UserAgent->new;

my $req = HTTP::Request->new( POST => $webhook_url );
$req->header( 'Content-Type' => 'application/json' );

my $json_payload = encode_json($payload);
$req->content($json_payload);

my $response = $ua->request($req);

# Check for a successful response
unless ( $response->is_success ) {
    die "Failed to send message: " . $response->status_line . "\n";
}
