
=head1 Download de arquivos das variaveis para montar excel de envio

=head2 Descrição

Download em /variaveis.csv

=cut

package Iota::Controller::VariaveisExemplo;
use Moose;
BEGIN { extends 'Catalyst::Controller' }
use utf8;
use JSON::XS;

use Text::CSV_XS;

sub _loc_str {
    my ( $self, $c, $str ) = @_;

    return $str if !defined $str || $str eq '';
    return $str unless $str =~ /[A-Za-z]/o;
    return $str if $str =~ /CONCATENAR/o;
    return $str if $str =~ /^\s*$/o;
    return $str if $str =~ /:\/\//o;

    return $c->loc($str);
}

# download de todos os endpoints caem aqui
sub _download {
    my ( $self, $c ) = @_;

    my $rs = $c->model('DB')->resultset('Variable');

    my $ignore_cache = 0;

    my $eixos;
    if ( $c->req->params->{from_indicators} ) {

        # da muito trabalho cachear essas informações "per user"
        # e nao compensa muito fazer isso agora.
        $ignore_cache = 1;

        my @users_ids =
          $c->req->params->{user_id} && $c->req->params->{user_id} =~ /^\d+$/
          ? ( $c->req->params->{user_id} )
          : @{ $c->stash->{network_data}{users_ids} };

        my $indicators_rs = $c->model('DB::Indicator')->filter_visibilities(
            user_id      => $c->stash->{current_city_user_id},
            networks_ids => $c->stash->{network_data}{network_id},
            users_ids    => \@users_ids,
        )->get_column('id')->as_query;

        my $variables_id_rs =
          $c->model('DB::IndicatorVariable')->search( { indicator_id => { 'in' => $indicators_rs } } )
          ->get_column('variable_id')->as_query;

        $rs = $rs->search( { 'me.id' => { 'in' => $variables_id_rs } } );

        $eixos = {
            map { $_->{variable_id} => $_->{eixo} } $c->model('DB::IndicatorVariable')->search(
                { indicator_id => { 'in' => $indicators_rs } },
                {
                    columns => [
                        qw/variable_id/,
                        { eixo => \'ARRAY(SELECT DISTINCT UNNEST( array_agg(axis.name))  ORDER BY 1) ' }
                    ],
                    join         => { 'indicator' => 'axis' },
                    group_by     => \'1',
                    result_class => 'DBIx::Class::ResultClass::HashRefInflator'
                }
            )->all
        };

    }

    my $file = $c->get_lang() . '_variaveis_exemplo.';

    # evita conflito com outros usuarios
    $file .= join '-', rand, rand, rand, rand, '.' if $ignore_cache;
    $file .= $c->stash->{type};

    my $path = ( $c->config->{downloads}{tmp_dir} || '/tmp' ) . '/' . lc $file;

    if ( -e $path ) {
        my $epoch_timestamp = ( stat($path) )[9];
        unlink($path) if time() - $epoch_timestamp > 60;
    }

    $self->_download_and_detach( $c, $path ) if !$ignore_cache && -e $path;

    $rs = $rs->as_hashref;

    my @lines =
      ( [ 'ID da variável', 'Nome', 'Data', 'Valor', 'fonte', 'Observacao', ( defined $eixos ? 'Eixos' : () ) ] );

    while ( my $var = $rs->next ) {
        push @lines,
          [
            $var->{id}, $self->_loc_str( $c, $var->{name} ),
            undef, undef, undef, undef,
            ( defined $eixos ? exists $eixos->{ $var->{id} } ? join ", ", @{ $eixos->{ $var->{id} } } : '-' : () )
          ];
    }

    if ( $0 && $0 =~ /\.t$/ ) {
        $c->stash->{lines} = \@lines;
    }
    else {
        eval { $self->lines2file( $c, $path, \@lines ) };
    }

    if ($@) {
        unlink($path);
        die $@;
    }
    $self->_download_and_detach( $c, $path, $ignore_cache );

    unlink($path) if $ignore_cache;
}

sub lines2file {
    my ( $self, $c, $path, $lines ) = @_;

    open my $fh, ">:encoding(utf8)", $path or die "$path: $!";
    if ( $path =~ /csv$/ ) {
        my $csv = Text::CSV_XS->new( { binary => 1, eol => "\r\n" } )
          or die "Cannot use CSV: " . Text::CSV_XS->error_diag();

        $csv->print( $fh, $_ ) for @$lines;

    }
    elsif ( $path =~ /xls$/ ) {
        binmode($fh);
        my $workbook = Spreadsheet::WriteExcel->new($fh);

        # Add a worksheet
        my $worksheet = $workbook->add_worksheet();

        #  Add and define a format
        my $bold = $workbook->add_format();    # Add a format
        $bold->set_bold();

        # Write a formatted and unformatted string, row and column notation.
        my $total = @$lines;

        for ( my $row = 0 ; $row < $total ; $row++ ) {

            if ( $row == 0 ) {
                $worksheet->write( $row, 0, $lines->[$row], $bold );
            }
            else {
                my $total_col = @{ $lines->[$row] };
                for ( my $col = 0 ; $col < $total_col ; $col++ ) {
                    my $val = $lines->[$row][$col];

                    if ( $val && $val =~ /^\=/ ) {
                        $worksheet->write_string( $row, $col, $val );
                    }
                    else {
                        $worksheet->write( $row, $col, $val );
                    }
                }
            }
        }

    }
    else {
        die("not a valid format");
    }
    close $fh or die "$path: $!";

}

sub _download_and_detach {
    my ( $self, $c, $path, $custom ) = @_;

    if ( $c->stash->{type} =~ /(csv)/ ) {
        $c->response->content_type('text/csv');
    }
    elsif ( $c->stash->{type} =~ /(xls)/ ) {
        $c->response->content_type('application/vnd.ms-excel');
    }
    $c->response->headers->header( 'content-disposition' => "attachment;filename="
          . "variaveis-exemplo-"
          . ( $custom ? 'dos-indicadores-' : 'completa-' )
          . $c->get_lang()
          . ".$1" );

    open( my $fh, '<:raw', $path );
    $c->res->body($fh);

    $c->detach;
}

sub doido_download_csv : Chained('/institute_load') : PathPart('variaveis_exemplo.csv') : Args(0) {
    my ( $self, $c ) = @_;
    $c->stash->{type} = 'csv';
    $self->_download($c);
}

sub download_xls : Chained('/institute_load') : PathPart('variaveis_exemplo.xls') : Args(0) {
    my ( $self, $c ) = @_;
    $c->stash->{type} = 'xls';
    $self->_download($c);
}

1;
