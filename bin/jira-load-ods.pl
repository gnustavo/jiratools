#!/usr/bin/env perl

# Copyright (C) 2011-2012 by Gustavo Chaves

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA

BEGIN { $ENV{PATH} = '/bin:/usr/bin' }

use utf8;
use strict;
use warnings;
use open ':utf8';
use Getopt::Long;
use IO::Handle;
use Encode;
use List::Util qw(first);
use Data::Dumper;

use OpenOffice::OODoc;
odfLocalEncoding 'utf8';
use LWP '5.836';		# version 5.820 has a bug in encoding non-ASCII post arguments
use WWW::Mechanize;
use HTML::TreeBuilder;
use File::Copy;

###############
# CONFIGURATION
my %JIRA = (
    url    => 'http://localhost:8080',
    fields => {		     # mapeamento de nome de campo para seu id
	'Ambiente'               => 'environment',
	'Componentes'            => 'components',
	'Data para Ficar Pronto' => 'duedate',
	'Descrição'              => 'description',
	'Prioridade'             => 'priority',
	'Responsável'            => 'assignee',
	'Resumo'                 => 'summary',
	'Versões'                => 'fixVersions',
	'Rótulos'                => 'labels',
	'Story points'           => 'customfield_10002',
	'Business value'         => 'customfield_10003',
    },
);

###################
# GROK COMMAND LINE

my $usage   = "$0 [--jiraurl JIRAURL] [--dont] [--verbose] [--debug DIR] [--project JIRA-PROJECT] ODSFILE ...\n";
my $Dont;
my $Verbose;
my $Debug;
my $Project;
GetOptions(
    'jiraurl=s' => \$JIRA{url},
    'dont'      => \$Dont,
    'verbose+'  => \$Verbose,
    'debug=s'   => \$Debug,
    'project=s' => \$Project,
) or die $usage;

not defined $Debug or -d $Debug or die "Not a directory: '$Debug'\n";

my $debug;

if ($Debug) {
    open $debug, '>', "$Debug/debug.txt" or die "Can't create '$Debug/debug.txt'";
    $debug->autoflush(1);
    $debug->print("--dont ") if $Dont;
    $debug->print("--verbose ") if $Verbose;
    $debug->print("--debug $Debug ") if $Debug;
    $debug->print("--project '$Project' ") if $Project;
    $debug->print(join(' ', @ARGV));
    $debug->print("\n");
}

# SPREADSHEET FUNCTIONS

# Sub read_spreadsheed receives the path to a ODF spreadsheet and
# returns a reference to a list of hashes. Each hash represents a row
# in the spreadsheet, mapping the header names (taken from the first
# row) to column values.

sub read_spreadsheet {
    my ($file) = @_;
    my $ods = odfDocument(file => $file, part => 'content')
	or die "Cannot open file $file\n";

    copy($file => $Debug) if $Debug;

    # We have to force the spreadsheet normalization because otherwise
    # we can miss some cells
    # (http://rt.cpan.org/Ticket/Display.html?id=57330). Also, it's
    # safest to use getTableRows in order to get the number of rows
    # instead of relying on getTableSize, because the later can give a
    # huge value if some formatting was performed in the whole of a
    # column.

    my ($nrows, $ncols) = $ods->getTableSize(0);
    $nrows = $ods->getTableRows(0);
    $ods->normalizeSheet(0, $nrows, $ncols);

    my @rows = $ods->getTableText(0);

    # I think this shouldn't be necessary, but we need to force the
    # encodind of the text gotten from the spreadsheet.
    foreach my $row (@rows) {
	$row = [map {Encode::decode_utf8($_)} @$row];
    }

    my $headers = shift @rows
	or die "Spreadsheet $file must contain at least one row.\n";

    my @tkts;
    foreach my $row (@rows) {
	my %tkt;
	@tkt{@$headers} = @$row;
	last unless $tkt{Resumo}; # skip empty rows at the end if there is some
	push @tkts, \%tkt;
    }

    $debug->print("SPREADSHEET:\n", Dumper(\@tkts)) if $Debug;

    return \@tkts;
}

# JIRA FUNCTIONS

# Sub option_id receives three arguments: a HTML::TreeBuilder $tree,
# the $name of a select tag in the $tree, and a $label which is a
# newline separated list of substrings. The substrings are looked for
# in the named select tag and the sub returns the corresponding list
# of option values found. The sub maitains a cache of the values found
# to avoid having to look them over and over again.

my %option_ids;
sub option_id {
    my ($tree, $name, $labels) = @_;

    unless (exists $option_ids{$name}{$labels}) {

	my %labels = map { lc($_) => $_ } split /\n/, $labels;

	my $select = $tree->look_down(
	    _tag => 'select',
	    name => $name,
	) or scraping_error(option_id => "Can't find select tag with name $name for ($labels).\n");

	my %values;

	foreach my $option ($select->find('option')) {
	    my @strings = grep {defined && ! ref} $option->content_list;
	    # There should be only one string. I'll take the first one;
	    my $string = shift @strings
		or scraping_error(option_id => "Found an option with no content while selecting '$name'.\n");
	    $string =~ s/^\s+//s; # stripping leading whitespace
	    $string =~ s/\s+$//s; # stripping trailing whitespace
	    $values{$string} = $option->attr('value')
		if delete $labels{lc $string};
	}

	%labels and
	    scraping_error(option_id => "Couldn't find the following labels while selecting '$name':\n    '" . join("'\n    '", sort values %labels) . "'\n");

	$option_ids{$name}{$labels} = [values %values];
    }

    return wantarray ? @{$option_ids{$name}{$labels}} : $option_ids{$name}{$labels}[0];
}

# Sub goto_create_ticket_page receives the WWW::Mechanize $jira object
# and a string specifying the $type of the ticket that we're going to
# create, which must be a parent ticket and not a sub-task. It gets
# the CreateIssue page and selects the appropriate project and ticket
# type from the form, leaving the $jira object facing the page where
# the ticket fields must be entered.

sub goto_create_ticket_page {
    my ($jira, $type, $project) = @_;

    $jira->get('/secure/CreateIssue!default.jspa');
    debug('goto_create_ticket_page BEGIN');

    {
	my $quiet = $jira->quiet(1);	    # avoid spurious warnings
	$jira->form_id('issue-create') # From JIRA 4.3 on
	    or $jira->form_name('jiraform') # Up to JIRA 4.1
		or scraping_error(goto_create_ticket_page => "can't find neither 'jiraform' nor 'issue-create' forms");
	$jira->quiet($quiet);
    }

    my $tree = HTML::TreeBuilder->new_from_content($jira->content);

    $jira->select(pid       => option_id($tree, 'pid',       $project));
    $jira->select(issuetype => option_id($tree, 'issuetype', $type   ));
    $jira->submit;
    debug('goto_create_ticket_page END');

    $tree->delete;
}

# Sub goto_create_subticket_page receives the WWW::Mechanize $jira
# object and a string specifying the key of the $parent ticket for
# which we're going to create a sub-task. It gets the $parent ticket
# page and then follows the create-subtask link, leaving the $jira
# object facing the page where the subtask fields must be entered.

sub goto_create_subticket_page {
    my ($jira, $parent) = @_;

    $jira->get("/browse/$parent");
    debug('goto_create_subticket_page BEGIN');
    eval { $jira->follow_link(id_regex => qr/^create[_-]subtask$/) };
    scraping_error(goto_create_subticket_page => "can't follow link create[_-]subtask", $@) if $@;

    my $tree = HTML::TreeBuilder->new_from_content($jira->content);

    # If the project can have only one type of sub-task then we go
    # directly to the create sub-task form. However, if there is more
    # than one possibility, then we have to select the appropriate
    # type first.

    $jira->form_id('subtask-create-start') # This works from JIRA 4.4 on
	or $jira->form_name('jiraform')	   # This works until JIRA 4.3
	    or scraping_error(goto_create_subticket_page => "Can't find neither 'subtask-create-start' nor 'jiraform' forms");

    if (eval {$jira->select(issuetype => option_id($tree, 'issuetype', 'Sub-task'))}) {
	$jira->submit;
	debug('goto_create_subticket_page SUBTASK SELECTED');
    }

    $tree->delete;
}

# Sub check_issue_page is used to check if we ended up in an issue
# page and if it doesn't have any error message displayed. If it does,
# we die accordingly.

sub check_issue_page {
    my ($jira, $line, $note) = @_;
    my $url = $jira->uri;
    unless ($url->path =~ m:.*/[a-z]+-\d+(\?|$):i) {
	my $error = "$note\[$line\]: I should be at an issue page but I got here instead: $url";
	my $html = HTML::TreeBuilder->new_from_content($jira->content);
	my $message = $html->look_down(_tag => 'span', class => 'errMsg');
	$message    = $html->look_down(_tag => 'div' , class => 'error' ) unless $message;
	if ($message) {
	    scraping_error(check_issue_page => "$error. Look at this message: '" . $message->as_text . "'");
	} else {
	    scraping_error(check_issue_page => "$error. Strangely, I can't find an error message in it.");
	}
    }
}

# Sub load_jiras receives the reference to hash list returned from
# read_spreadsheet and creates a JIRA ticket for each hash. The
# variable $last_ticket holds the key of the last created ticket,
# discounting sub-tasks. This allows for sub-task specifying rows to
# avoid mentioning the parent ticket key.

my $last_ticket;

sub load_jiras {
    return if $Dont;
    my ($jira, $rows) = @_;
    my $line = 1;
    $last_ticket = undef;
    foreach my $row (@$rows) {
	++$line;
	if ($row->{Tipo} eq 'Sub-task') {
	    my $parent_id = $row->{Mãe} || $last_ticket;
	    warn "$line: Sub-task[$parent_id] '$row->{Resumo}'\n" if $Verbose;
	    goto_create_subticket_page($jira, $parent_id);
	}
	else {
	    warn "$line: $row->{Tipo} '$row->{Resumo}'\n" if $Verbose;
	    my $project = $row->{Projeto} || $Project;
	    goto_create_ticket_page($jira, $row->{Tipo}, $project);
	}

	# Insert a mark in every ticket created by this load
	if ($row->{'Rótulos'}) {
	    $row->{'Rótulos'} .= " load_ods";
	} else {
	    $row->{'Rótulos'} = "load_ods";
	}

	# Fields like 'Rótulos', which were text fields until
	# JIRA 4.3, became a JavaScript generated select list in JIRA
	# 4.4. So, we have to fake them.
	my $faked_select_fields;
	foreach my $field (
	    'Rótulos',
	) {
	    next unless $row->{$field};
	    my $options = join("\n", map {"<option value=\"$_\" title=\"$_\">$_</option>"} split(' ', $row->{$field}));
	    my $id      = $JIRA{fields}{$field};

	    if ((my $html = $jira->content) =~ s:(<select [^>]+name=\"$id\"[^>]*>):$1$options:s) {
		$jira->update_html($html);
		$row->{$field} = join("\n", split(' ', $row->{$field}));
		$faked_select_fields = 1;
		debug("load_jiras after faking '$field'");
	    }
	}

	# Select field form
	{
	    my $quiet = $jira->quiet(1);   # avoid spurious warnings
	    $jira->form_id('issue-create') # From JIRA 4.3 on
		or $jira->form_id('subtask-create-details') # From JIRA 4.4 on
		    or $jira->form_name('jiraform') # Up to JIRA 4.1
			or scraping_error(load_jiras => "$line: Can't find neither 'issue-create', nor 'subtask-create-details', nor 'jiraform' forms");
	    $jira->quiet($quiet);
	}

	my $tree = HTML::TreeBuilder->new_from_content($jira->content);

	foreach my $field (
	    'Rótulos',
	) {
	    next unless $row->{$field};
	    if ($faked_select_fields) {
		$jira->select($JIRA{fields}{$field}
				  => [option_id($tree, $JIRA{fields}{$field}, $row->{$field})]);
	    } else {
		$jira->field($JIRA{fields}{$field} => $row->{$field});
	    }
	    debug("load_jiras after rewriting field '$field'");
	}

	$jira->field(summary => $row->{Resumo});

        # Campo Responsável: Note that an empty string means that the
        # assignee will be the default one and not that there will be
        # no assignee. If you want to specify "no assignee", use the
        # string "Nenhum".
	if (my $assignee = $row->{Responsável}) {
	    $assignee =~ /^\w+$/i
		or die "$line: Invalid 'Responsável' ($assignee): It must be a username.\n";

	    $assignee = '' if $assignee =~ /^Nenhum$/i;
	    $jira->field(assignee => $assignee);
	}

	if (my $time = $row->{'Tempo Estimado'}) {
	    my $period = qr/\d+[wdhm]/;
	    $time =~ /^$period(?:\s+$period)*$/
		or die "$line: Invalid 'Tempo Estimado' ($time): The format of this is '*w *d *h *m' (representing weeks, days, hours, and minutes - where * can be any number). Examples: 4d, 5h 30m, 60m, and 3w.)\n";
	    $jira->field(timetracking_originalestimate => $time);
	}

	# Text fields
	foreach my $field (
	    'Ambiente',
	    'Business Value',
	    'Data para Ficar Pronto',
	    'Descrição',
	    'Story Points'
	) {
	    $jira->field($JIRA{fields}{$field} => $row->{$field}) if $row->{$field};
	}

	# Select fields
	foreach my $field (
	    'Prioridade',
	) {
	    $jira->select($JIRA{fields}{$field} => option_id($tree, $JIRA{fields}{$field}, $row->{$field}))
		if $row->{$field};
	}

	# Multiple select fields
	for my $field (
	    'Componentes',
	    'Versões'
	) {
	    $jira->select($JIRA{fields}{$field} => [option_id($tree, $JIRA{fields}{$field}, $row->{$field})])
		if $row->{$field};
	}

	$jira->submit();
	debug('load_jiras AFTER SUBMIT');

	check_issue_page($jira, $line, 'SUBMIT');

	(my $ticket_id = $jira->uri->path) =~ s:.*/([a-z]+-\d+)$:$1:i;

	warn "  -> $ticket_id\n" if $Verbose;

	$last_ticket = $ticket_id
	    unless $row->{Tipo} eq 'Sub-task';

	$tree->delete;

	if (my $linkkey = $row->{Associado}) {
	    my $linktype = $row->{'Associação'}
		or die "$line: Missing 'Associação' value.\n";
	    warn "  -- linking as '$linktype' $linkkey\n" if $Verbose;
	    $jira->follow_link(id => 'link-issue')
		or scraping_error(load_jiras => "$line: Can't go to the Link page");
	    debug('load_jiras FOLLOWED LINK-ISSUE');
	    my $html = $jira->content;
	    # The following select fixtures are needed for JIRA 5.1
	    $html =~ s@(data-ajax-options.data.app-id="">)\s+(</select>)@$1<option value="$linkkey">$linkkey</option>$2@s;
	    $jira->update_html($html);
	    $tree = HTML::TreeBuilder->new_from_content($html);
	    $jira->form_id('link-jira-issue')
		or die "$line: Can't find link-jira-issue select for ticket linking.\n";
	    $jira->select(issueKeys => $linkkey);
	    $jira->select(linkDesc => option_id($tree, 'linkDesc', $linktype))
		or scraping_error(load_jiras => "$line: Can't select Link '$linktype'");
	    $jira->submit();
	    debug('load_jiras AFTER LINK-ISSUE');
	    check_issue_page($jira, $line, 'LINK-ISSUE');
	    $tree->delete;
	}
    }
}

# MAIN

# Login to the JIRA instance

my $jira = WWW::Mechanize->new(stack_depth => 0, autocheck => 1);

# See: https://developer.atlassian.com/display/JIRADEV/Form+Token+Handling
$jira->add_header('X-Atlassian-Token' => 'no-check');

# Generic function to produce error messages with lots of information
# about the scraping context.

sub scraping_error {
    my ($foo, $msg, $die) = @_;
    my $uri = $jira->uri;
    $debug->print("ERROR in $foo for ($uri).\n",
		  "MESSAGE: $msg\n",
		  $die ? "DIE: $die\n" : '',
		  "Page contents follow:\n",
		  $jira->content) if $Debug;
    die "ERROR in $foo for ($uri).\nMESSAGE: $msg.\n", ($die ? "DIE: $die.\n" : '');
}

# Generic function to produce debug information about the scraping context.

my $debug_id = 0;
sub debug {
    my ($msg) = @_;
    return unless $Debug;
    open my $file, '>', "$Debug/$debug_id.html" or die "Can't create '$Debug/$debug_id.html'";
    my $uri = $jira->uri;
    $file->print(<<"EOS");
<!--
URL: $uri
MSG: $msg
-->
EOS
    $file->print($jira->content);
    ++$debug_id;
}

$jira->get("$JIRA{url}/secure/Dashboard.jspa");
debug('MAIN START');

if ($jira->form_name('loginform')) {
    # JIRA 3 has the login form in the HTML
} else {
    # JIRA 4 makes heavy use of JavaScript, which we can't handle
    # easily from inside WWW::Mechanize. Hence, we fake a form that
    # would be generated on the fly in the JS-enabled browser and try
    # to lookup the form again.
    my $html = $jira->content;
    $html =~ s:</body>:<form id="loginform" method="POST" action="/rest/gadget/1.0/login" name="loginform" class="aui gdt">
  <fieldset>
    <div>
      <label id="usernamelabel" for="usernameinput" accesskey="u"></label>
      <input class="text medium-field" type="text" id="usernameinput" name="os_username" tabindex="1">
    </div>
    <div>
      <label id="passwordlabel" for="os_password" accesskey="p"></label>
      <input class="text medium-field" type="password" name="os_password" id="os_password" tabindex="2">
    </div>
    <div class="checkbox" id="rememberme">
      <input type="checkbox" name="os_cookie" id="os_cookie_id" tabindex="3" value="true">
      <label id="remembermelabel" for="os_cookie_id" accesskey="r"></label>
    </div>
    <div class="submit">
      <input id="login" class="button" type="submit" value="Log In" tabindex="4">
    </div>
  </fieldset>
</form>
</body>
:;
    $jira->update_html($html);
    $jira->form_name('loginform')
	or scraping_error(MAIN => "Can't find login form");
}

{
    sub get_credentials {
	my ($userenv, $passenv, %opts) = @_;

	require Term::Prompt; Term::Prompt->import();

	$opts{prompt}      ||= '';
	$opts{userhelp}    ||= '';
	$opts{passhelp}    ||= '';
	$opts{userdefault} ||= $ENV{USER};

	my $user = $ENV{$userenv} || prompt('x', "$opts{prompt} Username: ", $opts{userhelp}, $opts{userdefault});
	my $pass = $ENV{$passenv};
	unless ($pass) {
	    $pass = prompt('p', "$opts{prompt} Password: ", $opts{passhelp}, '');
	    print "\n";
	}

	return ($user, $pass);
    }

    my ($user, $pass) = get_credentials('jirauser', 'jirapass', prompt => 'JIRA');
    $debug->print("user=$user\n") if $Debug;
    $jira->set_fields(os_username => $user, os_password => $pass);
}
$jira->submit();
debug('MAIN AFTER LOGIN');
scraping_error(MAIN => "couldn't log in")
    unless $jira->content =~ /"loginSucceeded":true/;

# Process each spreadsheet

foreach my $file (@ARGV) {
    my $spreadsheet = read_spreadsheet($file);

    # If we don't have a default Project we have to have a project
    # specified in every row. Let's check this before creating the
    # first issue.
    unless ($Project) {
	for (my $i=0; $i <= $#{$spreadsheet}; ++$i) {
	    die 'No default project has been specified and line ', $i+1, " has an empty cell 'Projeto'.\n"
		unless $spreadsheet->[$i]{Projeto};
	}
    }

    load_jiras($jira, $spreadsheet);
}
