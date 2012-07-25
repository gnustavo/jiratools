#!/usr/bin/perl -T

# Copyright (C) 2010 by CPqD

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

BEGIN { $ENV{PATH} = '/usr/bin:/bin' }

use utf8;
use strict;
use warnings;
use File::Temp qw/tempfile tempdir/;
use File::Copy;
use File::Spec::Functions qw/catfile tmpdir/;
use POSIX qw(strftime);
use CGI ':standard';

###############
# CONFIGURATION
my $TMPDIR = tmpdir();
my $INSTALLDIR = '/home/user/jiratools';
my $JIRAURL = 'http://localhost:8080';

$| = 1;				# don't buffer output

# force use of https
#my $url = url;
#if ($url =~ s/^http:/https:/i) {
#    print redirect(-url => $url, -status => 301);
#}

print
    header(),
    start_html('Carregador de Planilhas ODF no JIRA'),
    h1('Carregador de Planilhas ODF no JIRA');

print
    p("Baixe este ",
      a({href => '/jira-load-template.ods'}, 'modelo de planilha'),
      <<'EOS');
 e insira os dados dos tíquetes que você deseja carregar no JIRA. Cada
tíquete é descrito por uma linha da planilha, que deve manter a
primeira linha intacta e não deve adicionar ou remover colunas.
Se você especificar o nome de um produto JIRA abaixo ele será usado
para as linhas da planilha que não especificarem a coluna Produto. A
palavra-chave "load_ods" será automaticamente adicionada aos tíquetes
criados para que você possa buscá-los posteriormente.
EOS

print
    start_multipart_form,
    p("Usuário JIRA:", textfield('jirauser')),
    p("Senha JIRA:", password_field('jirapass')),
    p("Produto JIRA:", textfield('jiraprod')),
    p("Planilha preenchida:", filefield('odsfile')),
    p({-style => 'font-size: small'},
      checkbox(-name => 'debug', -checked => 1, -value => '--debug'),
      "(Marque se quiser gerar logs detalhados de depuração para os administradores.)"),
    submit,
    end_form,
    hr,
    "\n";

sub error {
    print p("ERRO: ", @_), end_html;
    exit;
}

sub detaint {
    my ($param, $pattern, $required) = @_;

    my $value = param($param);

    if (! $value) {
	error "Faltou o parâmetro $param" if $required;
	return undef;
    } elsif ($value =~ $pattern) {
	return $1;
    } else {
	error "O parâmetro '$param' deve casar com o padrão '$pattern'";
    }
}

if (param()) {
    # Grok and detaint parameters
    print p("# Lendo os argumentos..."), "\n";
    $ENV{jirauser} = detaint(jirauser => qr/^([\w-]+)$/, 'required');
    $ENV{jirapass} = detaint(jirapass => qr/^(.{1,16})$/, 'required');

    my $debug = detaint(debug    => qr/^(--debug|)$/);

    my $tmpdir = tempdir(strftime('load-ods-%F_%T_XXXX', localtime), TMPDIR => 1);

    if ($debug) {
	$debug .= " $tmpdir";
	print p("# Logs detalhados serão gerados no servidor em '$tmpdir'."), "\n";
    }

    my $jiraprod   = detaint(jiraprod => qr/^(.{0,80})$/);
    my $in_ods     = upload('odsfile');

    # Copy the odsfile spreadsheet to a temporary file
    my $odscopy = catfile($tmpdir, 'spreadsheet.ods');
    copy($in_ods, $odscopy)
	or error "Não consegui copiar a planilha no servidor: $!\n";

    # Load the spreadsheet
    print p("# Carregando a planilha..."), "\n";
    my $loader = catfile($INSTALLDIR, 'bin', 'jira-load-ods.pl');
    my $product_opt = $jiraprod ? "--product \"$jiraprod\"" : '';
    open LOADER, '-|:utf8', "$loader --verbose $debug $product_opt \"$odscopy\" 2>&1"
	or error "Não consegui executar o comando $loader: $!";
    print '<p>';
    while (<LOADER>) {
	# Insert a link to the ticket
	s@\b([A-Z]+-\d+)\b@a({href => "$JIRAURL/browse/$1"}, $1)@e;
	print $_, br, "\n";
    }
    print '</p>';
    close LOADER or error sprintf("O comando $loader terminou com erro %d.", $? >> 8), <<EOS;
Se ele foi causado por algum erro numa linha da planilha, corrija-a,
remova as linhas anteriores que já tenham sido carregadas e resubmeta
a planilha modificada. Atenção: se a nova planilha tiver uma
Sub-tarefa cuja 'Mãe' já tenha sido carregada ela precisará
especificar explicitamente o identificador do tíquete da mãe.
EOS
    print "# Sucesso!", p, hr;
}

print end_html;
