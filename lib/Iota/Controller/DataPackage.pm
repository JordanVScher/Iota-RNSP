
=head1 Gerar o arquivo de data package

=head2 Descrição

http://data.okfn.org/standards/data-package


=cut

package Iota::Controller::DataPackage;
use Moose;
use DateTime::Format::Pg;

BEGIN { extends 'Catalyst::Controller::REST' }
__PACKAGE__->config( default => 'application/json' );
use utf8;

sub _download {
    my ( $self, $c ) = @_;

    my $ret         = {};
    my $description = '';
    my $title       = '';
    my $name        = '';
    my @keywords;

    my $data_rs = $c->model('DB::DownloadData')->search( { institute_id => $c->stash->{institute}->id },
        { result_class => 'DBIx::Class::ResultClass::HashRefInflator' } );

    my $data_rs_region =
      $c->model('DB')->resultset( exists $c->stash->{region} ? 'ViewDownloadVariablesRegion' : 'DownloadVariable' )
      ->search(
        { institute_id => $c->stash->{institute}->id },
        {
            result_class => 'DBIx::Class::ResultClass::HashRefInflator',

            exists $c->stash->{region}
            ? ( bind => [ ( $c->stash->{region}->id ) x 2 ] )
            : ()
        }
      );


    my $network = $c->stash->{network};

    $description .= $network->name;
    if ($c->stash->{cidade}){
        my $city = $c->stash->{city};
        $description .= ', ' . $c->loc('País') . ': ' . $c->stash->{pais} . ', ';
        $description .= $c->loc('Estado') . ': ' . $c->stash->{estado} . ', ';
        $description .= $c->loc('Cidade') . ': ' . $city->{name};

        $ret->{$_} = $city->{$_} for qw/country_id latitude longitude/;
        $ret->{city_id} = $city->{id};

        $title .= $c->stash->{pais} . ',';
        $title .= $city->{name} . '/';
        $title .= $c->stash->{estado};

        $name .= join '.', $c->stash->{pais}, $c->stash->{estado}, $c->stash->{cidade};



    }

    if ($c->stash->{region}){
        $description .= $c->loc( $c->stash->{region_classification_name}{ $c->stash->{region}->depth_level } ) . ': ' . $c->stash->{region}->name;
        $title .= ' - ' . $c->stash->{region}->name;

        $name .= '_' . $c->stash->{region}->name_url;
    }


    if ($c->stash->{indicator}){
        $description .= $c->loc('Indicador') . ': ' . $c->stash->{indicator}{name};

        $title .= ': ' . $c->stash->{indicator}{name};
        $name .= '_' . $c->stash->{indicator}{name_url};
    }

    $name = $network->name_url unless $name;
    $title = $network->name unless $title;

    if ( $c->stash->{cidade} ) {

        # procula pela cidade, se existir.
        my $cities = $c->model('DB::City')->as_hashref->search(
            {
                pais     => lc $c->stash->{pais},
                uf       => uc $c->stash->{estado},
                name_uri => lc $c->stash->{cidade}
            }
        )->next;

        my $id = $cities ? $cities->{id} : -9012345;    # download vazio
        $data_rs        = $data_rs->search( { city_id => $id } );

         my $user = $c->model('DB::User')->as_hashref->search(
            {
                city_id                    => $id,
                'network_users.network_id' => $network->id
            },
            { join => 'network_users' }
        )->next;

        $data_rs_region = $data_rs_region->search( { user_id => $user ? $user->{id} : -9012345 } );

    }

    if ( exists $c->stash->{indicator} ) {
        $data_rs = $data_rs->search( { indicator_id => $c->stash->{indicator}{id} } );


        $data_rs_region = $data_rs_region->search(
            {
                variable_id => {
                    'in' => [
                        (
                            map { $_->variable_id }
                              $c->model('DB::IndicatorVariable')
                              ->search( { indicator_id => $c->stash->{indicator}{id} } )->all
                        ),

                        (
                            map { -( $_->id ) }
                              $c->model('DB::IndicatorVariation')
                              ->search( { indicator_id => $c->stash->{indicator}{id} } )->all
                        )
                    ]
                }
            }
        );

    }

    if ( exists $c->stash->{region} ) {
        $data_rs = $data_rs->search( { region_id => $c->stash->{region}->id } );

        $data_rs_region = $data_rs_region->search( { region_id => $c->stash->{region}->id } );
    }
    else {
        $data_rs = $data_rs->search( { region_id => undef } );
    }


    my $last1 = $data_rs->get_column('updated_at')->max();
    my $last2 = $data_rs_region->get_column('updated_at')->max();

    $last1 = DateTime::Format::Pg->parse_datetime($last1)
        if $last1;

    $last2 = DateTime::Format::Pg->parse_datetime($last2)
        if $last2;

    my $last_updated =
        ref $last1 eq 'DateTime' &&
        ref $last2 eq 'DateTime'
        ?
            DateTime->compare( $last1, $last2 ) == 1
            ? $last1->datetime
            : $last2->datetime
        :
            $last1 ? $last1->datetime :
            $last2 ? $last2->datetime : undef;

    my $base_url = 'http://' . $network->domain_name . $c->req->uri->path;
    $base_url =~ s/\/datapackage.json$//;

    my $name_arq = 'indicadores';
    $name_arq = 'dados' if ( exists $c->stash->{indicator} );


    $ret = {
        %$ret,
        name =>  $name,
        title =>  $title,
        description =>  $description,
        licenses =>  [
            {
                id =>  "1",
                url =>  "fake-but-free"
            }
        ],
        keywords     =>  [ @keywords ],
        version      =>  "iota-v$Iota::VERSION",
        last_updated =>  $last_updated,
        image        =>  "http://indicadores.cidadessustentaveis.org.br/static/images/logo.png",
        resources =>  [
            {
                path => "$base_url/variaveis.csv"
            },
            {
                path => "$base_url/$name_arq.csv"
            }
        ]
    };



    if ($@) {
        $self->status_bad_request( $c, message => "$@", );
    }
    else {
        $self->status_ok( $c, entity => $ret );
    }
}


for my $chain (
    qw/institute_load network_cidade cidade_regiao network_indicator network_indicador cidade_regiao_indicator/) {
    for my $tipo (qw/json/) {
        eval( "
            sub chain_${chain}_${tipo} : Chained('/$chain') : PathPart('datapackage.$tipo') : CaptureArgs(0) {
                my ( \$self, \$c ) = \@_;
                \$c->stash->{type} = '$tipo';
            }

            sub render_${chain}_${tipo} : Chained('chain_${chain}_${tipo}') : PathPart('') : Args(0) {
                my ( \$self, \$c ) = \@_;
                \$self->_download(\$c);
            }
        " );
    }
}
1;

