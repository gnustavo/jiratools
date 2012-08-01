#!/usr/bin/env perl

use 5.010;
use utf8;
use strict;
use warnings;
use Getopt::Long;
use List::MoreUtils qw/uniq/;
use App::gh::Git;

######################
# Global Configuration

my $jirakey = qr/\b[A-Z][A-Z]+-\d+\b/;

###################
# Option processing

my $usage   = "$0 [--jiraurl=URL] [--gitdir=DIR] [--[no]jira] [COMMIT..COMMIT]\n";
my $JIRAURL = 'https://jira.example.com';
my $GitDir = '.';
my $JIRA   = 1;
GetOptions(
    'jiraurl=s' => \$JIRAURL,
    'gitdir=s'  => \$GitDir,
    'jira!'     => \$JIRA,
) or die $usage;

######################
# Grok git commit logs

my $git = App::gh::Git->repository(Directory => $GitDir);

my @commits;
{
    # See 'git help log' to understand the --pretty argument
    my ($pipe, $ctx) = $git->command_output_pipe('log', '-z', '--date=iso', '--name-only', @ARGV);
    local $/ = "\x00\x00";
    while (<$pipe>) {
	chomp;
	my ($commit, $author, $date, undef, @body) = split /\n/;
	$commit =~ s/^commit\s+//  or die "Cannot grok commit line from $_";
	$author =~ s/^Author:\s+// or die "Cannot grok author line from $_";
	$date   =~ s/^Date:\s+//   or die "Cannot grok date   line from $_";
	my $msg;
	while (@body && $body[0] =~ /^ {4}(.*)/) {
	    $msg .= "$1\n";
	    shift @body;
	}
	shift @body;		# skip a blank line before the file list
	push @commits, {
	    commit => $commit,
	    author => $author,
	    date   => $date,
	    msg    => $msg,
	    files  => \@body,
	};
    }
    $git->command_close_pipe($pipe, $ctx);
}

################
# Grok JIRA keys

my %jiras;
foreach my $commit (@commits) {
    my @keys = uniq($commit->{msg} =~ /$jirakey/g);
    foreach my $key (@keys) {
	push @{$jiras{$key}}, @{$commit->{files}};
    }
}

if ($JIRA) {
    sub get_credentials {
	my ($userenv, $passenv, %opts) = @_;

	$opts{prompt}      ||= '';
	$opts{userhelp}    ||= '';
	$opts{passhelp}    ||= '';
	$opts{userdefault} ||= $ENV{USER};

	my $user = $ENV{$userenv};
	unless ($user) {
	    require Term::Prompt;
	    $user = Term::Prompt::prompt('x', "$opts{prompt} Username: ", $opts{userhelp}, $opts{userdefault});
	}

	my $pass = $ENV{$passenv};
	unless ($pass) {
	    require Term::Prompt;
	    $pass = Term::Prompt::prompt('p', "$opts{prompt} Password: ", $opts{passhelp}, '');
	    print "\n";
	}

	return ($user, $pass);
    }

    require JIRA::Client;
    my $jira = JIRA::Client->new($JIRAURL, get_credentials('jirauser', 'jirapass', prompt => 'JIRA'));

    say 'KEY,ASSIGNEE,SUMMARY';
    foreach my $key (sort keys %jiras) {
	my $issue = eval {$jira->getIssue($key)};
	if ($@) {
	    warn "WARN: cannot get issue '$key': $@\n";
	    next;
	}
	no warnings;		# avoid warnings for uninitialized keys
	say '"', join('","' => @{$issue}{qw/key assignee summary/}), '"';
    }
} else {
    say 'KEY';
    foreach my $key (sort keys %jiras) {
	say $key;
    }
}

say "\nJIRA,FILE";

foreach my $key (sort keys %jiras) {
    my @files = uniq sort @{$jiras{$key}};
    foreach my $file (@files) {
	say "\"$key\",\"$file\"";
    }
}


__END__
=head1 NAME

git-log-jiras.pl - Grok info about JIRA keys cited in Git logs.

=head1 SYNOPSIS

git-log-jiras.pl [--gitdir=DIR] [--[no]jira] [COMMIT..COMMIT]

=head1 DESCRIPTION

This script generates a text report (in CSV format) summarizing
information about each and every JIRA key cited in a list of Git
commit messages.

The list of commits is specified by the optional C<COMMIT..COMMIT>
argument, which is passed to the C<git log> command. You should read
C<git help log> documentation to understand how can you specify the
commits you want.

The report has two parts separated by a blank link, in the following
format:

	KEY,ASSIGNEE,SUMMARY
	"CDS-30","john","Weird error message in X."
	"CDS-33","mary","Wrong pluralization of octopus."
	"LP-432","matt","Cannot print in color."

	JIRA,FILE
	"CDS-30","path/to/X.pl"
	"CDS-33","path/to/octopuses.pl"
	"CDS-33","path/to/octopi.pl"
	"CDS-33","path/to/octopodes.pl"
	"LP-432","lib/color.pl"

The first part lists every JIRA key cited by the commits. It lists one
JIRA key per line, informing its current assignee and summary. This
information is fetched from your JIRA server, which URL is fixed in
the $JIRAURL variable at the beginning of the script. In the example
above, three JIRA keys were cited by all commits specified. Perhaps
some of them were cited more than once, but each key is mentioned just
once in the part.

The second part lists, for each JIRA key, all the files that were
affected by commits citing it. So, in the example above, the key
C<CDS-30> was cited by commits that affected the file C<path/to/X.pl>,
while the key C<CDS-33> was cited by commits that affected three
different files. So, each key may appear more than once in this, part.

In order to connect to your JIRA server, the script will need your
credentials. It will ask you for your username and password
interactivelly. If you need the script to run non-interactivelly, you
may pass your credentials to it via the environment variables
C<jirauser> and C<jirapass>.

=head1 OPTIONS

=over

=item --gitdir=DIR

You should normally invoke the script from a Git repository. If you
need to invoke it from elsewhere, you may use this option to tell it
where is your repository.

=item --[no]jira

By default, this script will try to get the current assignee and
summary of each key found in the commit messages. If you don't want
this or if you don't have connection to your JIRA server you may
disable this by passing the C<--nojira> option to the script. If you
do this, the first part of the report will contain just the JIRA keys.

=back

=head1 COPYRIGHT

Copyright 2012 CPqD.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Gustavo Chaves <gustavo@cpqd.com.br>
