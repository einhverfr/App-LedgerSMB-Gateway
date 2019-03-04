package App::LedgerSMB::Gateway::Internal::Reports;
use App::LedgerSMB::Auth qw(authenticate);
#use lib "/home/ledgersmb/LedgerSMB/lib";
use lib "/opt/ledgersmb/";
use Try::Tiny;
use App::LedgerSMB::Gateway::Internal::Locale;
use LedgerSMB::Sysconfig;
use LedgerSMB::PGDate;
use Log::Log4perl;
use Dancer ':syntax';
use Dancer::HTTP;
use Dancer::Serializer;
use Dancer::Response;
use Dancer::Plugin::Ajax;
use LedgerSMB::Report::Balance_Sheet;
use LedgerSMB::Report::PNL::Income_Statement;
use LedgerSMB::Report::Aging;
use LedgerSMB::Report::Invoices::Transactions;
use DateTime;
use DateTime::TimeZone;

my $locale = App::LedgerSMB::Gateway::Internal::Locale->new();

my %mime = (
   html => 'text/html',
   csv => 'text/csv',
   pdf => 'application/pdf',
);

{
  no strict 'refs';
  my $to_json = sub($@) { my ($self) = @_; return $self->to_db() };
  *LedgerSMB::PGNumber::TO_JSON = $to_json;
  *LedgerSMB::PGDate::TO_JSON =  $to_json;
}
$ENV{REQUEST_METHOD} = '';

prefix '/lsmbgw/0.1/:company/internal/reports';
get '/balance_sheet/:date/:format' => sub { formatted_balance_sheet(param('date'), param('format')); };
get '/balance_sheet/:date' => sub { to_json(balance_sheet(param('date'))) };
get '/:class/transactions/:date' => sub { to_json(transactions(param('class'), param('date'))) };
get '/:class/transactions/:date/:format' =>  sub { transactions(param('class'), param('date'), param('format')) };
get '/:class/aging/:date/summary' => sub { to_json(aging_summary(param('class'), param('date'))) };
get '/:class/aging/:date/:format' => sub { my $data = formatted_aging(param('class'), param('date'), param('format')); return $data };
get '/:class/aging/:date' => sub { to_json(aging(param('class'), param('date') )) };

get '/pnl/:from_date/:to_date/:format' => sub { my $data = formatted_pnl(param('from_date'), param('to_date'), param('format')); return $data };
get '/pnl/:from_date/:to_date' => sub { to_json(pnl(param('from_date'), param('to_date'))) };

sub pnl {
    my ($from, $to, $format) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    $from = LedgerSMB::PGDate->from_db($from, 'date');
    $to = LedgerSMB::PGDate->from_db($to, 'date');
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $report = LedgerSMB::Report::PNL::Income_Statement->new(
          date_from => $from, date_to => $to, legacy_hierarchy => 1,
          comparison_type => 'periods', basis => 'accrual', ignore_yearend => 'all', locale => $locale,
    );
    $report->run_report;
    return {rows => $report->rheads->ids, display_order => $report->rheads->sort } unless $format;  

    $report->sorted_row_ids($report->rheads->sort);
    $report->sorted_col_ids($report->cheads->sort);

    my $bs = render_report($report, $format);
    my $data = template_contents($bs);
    return send_file(\$data, content_type => $mime{$format});
}


sub formatted_pnl {
    my ($from, $to, $format) = @_;
    return pnl($from, $to, $format);
}

sub balance_sheet {
    my ($date, $format) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    $date = LedgerSMB::PGDate->from_db($date, 'date');
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $report = LedgerSMB::Report::Balance_Sheet->new(
          date_to => $date, legacy_hierarchy => 1, format => uc($format)
    );
    $report->run_report;
    return {rows => $report->rheads->ids, display_order => $report->rheads->sort } unless $format;  
    $report->sorted_row_ids($report->rheads->sort);
    $report->sorted_col_ids($report->cheads->sort);

    my $bs = render_report($report, $format);
    my $data = template_contents($bs);
    return send_file(\$data, content_type => $mime{$format});
}

sub formatted_balance_sheet {
    my ($date, $format) = @_;
    return balance_sheet($date, $format);
}

sub transactions {
    my ($class, $date, $format) = @_;
    my $eclass;
    if (lc $class eq 'ar'){
        $eclass = 2;
    } elsif (lc $class eq 'ap') {
        $eclass = 1;
    } else {
        die "bad aging report. Class needs to be ar or ap, was $class";
    }
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    $date = LedgerSMB::PGDate->from_db($date, 'date');
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $report = LedgerSMB::Report::Invoices::Transactions->new(
          date_to => $date, entity_class => $eclass, report_type => 'summary', to_date => $date, open => 1, closed => 1,
    );
    eval { $report->run_report };
    $report->rows();
    return $report->rows() unless $format;  
    my $bs = render_report($report, $format);
    my $data = template_contents($bs);
    return send_file(\$data, content_type => $mime{$format});
}

sub aging {
    my ($class, $date, $format) = @_;
    my $eclass;
    if (lc $class eq 'ar'){
        $eclass = 2;
    } elsif (lc $class eq 'ap') {
        $eclass = 1;
    } else {
        die "bad aging report. Class needs to be ar or ap, was $class";
    }
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    $date = LedgerSMB::PGDate->from_db($date, 'date');
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1,000.00'};
    my $report = LedgerSMB::Report::Aging->new(
          date_to => $date, entity_class => $eclass, report_type => 'summary', to_date => $date
    );
    $report->{report_name} = uc($class) . " Aging";
    eval { $report->run_report };
    $report->rows();
    return $report->rows() unless $format;  
    my $bs = render_report($report, $format);
    my $data = template_contents($bs);
    return send_file(\$data, content_type => $mime{$format});
}

sub formatted_aging {
    my ($class, $date, $format) = @_;
    return aging($class, $date, $format);
}

sub bs_summary {
    my ($date) = @_;
    my $rows = balance_sheet($date);
}

sub aging_summary {
    my $rows = aging(@_);
}


sub template_contents {
    my ($template) = @_;
    warning($template->{output});
    warning($template->{rendered});
    return $template->{output} if $template->{output};
    open DATA, '<', $template->{rendered};
    my $data = join('', <DATA>);
    close DATA;
    return $data;
}


sub render_report {
    my ($self, $format) = @_;
    warning(to_json($self->rows));
    my $template;
    my $request = {};
    my $dt = DateTime->now()->set_time_zone('America/New_York');
    $self->{nowtime} = $dt->ymd . ' ' . $dt->hms . ' Eastern Time';
    my $testref = $self->rows;
    $self->run_report($request) if !defined $testref;
    # This is a hook for other modules to use to override the default
    # template --CT
    eval {$template = $self->template};
    $template ||= 'Reports/display_report';

    # Sorting and Subtotal logic
    my $url = LedgerSMB::App_State::get_relative_url() // '';
    $self->order_dir('asc') if defined $self->order_by;
    if (defined $self->old_order_by and ($self->order_by eq $self->old_order_by)){
        if (lc($self->order_dir) eq 'asc'){
            $self->order_dir('desc');
        } else {
            $self->order_dir('asc');
        }
    }
    $url =~ s/&?order_by=[^\&]*//g;
    $url =~ s/&?order_dir=[^\&]*//g;
    $self->order_url($url);
    $self->order_url(
        "$url&old_order_by=".$self->order_by."&order_dir=".$self->order_dir
    ) if $self->order_by;

    my $rows = $self->rows;
	warning(to_json($_)) for @$rows;


    @$rows = sort {
                   my $srt_a = $a->{$self->order_by};
                   my $srt_b = $b->{$self->order_by};
                   $srt_a = $srt_a->to_sort if eval { $srt_a->can('to_sort') };
                   $srt_b = $srt_b->to_sort if eval { $srt_b->can('to_sort') };
                   no warnings 'numeric';
                   $srt_a <=> $srt_b or $srt_a cmp $srt_b;
              } @$rows
      if $self->order_by;


    if ($self->order_dir && $self->order_by
        && lc($self->order_dir) eq 'desc') {
        @$rows = reverse @$rows;
    }
    #$self->rows($rows);
    my $total_row = {html_class => 'listtotal', NOINPUT => 1};
    my $col_val = undef;
    my $old_subtotal = {};
    my @newrows;
    my $exclude = $self->_exclude_from_totals;

    for my $r (@{$self->rows}){
        for my $k (keys %$r){
            next if $exclude->{$k};
            if (eval { $r->{$k}->isa('LedgerSMB::PGNumber') }){
                $total_row->{$k} ||= LedgerSMB::PGNumber->from_input('0');
                $total_row->{$k}->badd($r->{$k});
            }

        }
        if ($self->show_subtotals and defined $col_val and
            ($col_val ne $r->{$self->order_by})
         ){
            my $subtotals = {html_class => 'listsubtotal', NOINPUT => 1};
            for my $k (keys %$total_row){
                $subtotals->{$k} = $total_row->{$k}->copy
                        unless $subtotals->{k};
                $subtotals->{$k}->bsub($old_subtotal->{$k})
                        if ref $old_subtotal->{$k};
            }
            push @newrows, $subtotals;
         }
         push @newrows, $r;
    }
    push @newrows, $total_row unless $self->manual_totals;
    $self->rows(\@newrows);
    # Rendering

    $self->format('html') unless defined $self->format;
    my $name = $self->name || '';
    $name =~ s/ /_/g;
    $name = $name . '_' . $self->from_date->to_output
            if $self->can('from_date')
               and defined $self->from_date
               and defined $self->from_date->to_output;
    $name = $name . '-' . $self->to_date->to_output
            if $self->can('to_date')
               and defined $self->to_date
               and defined $self->to_date->to_output;
    my $columns = $self->show_cols({});

    for my $col (@$columns){
        $col->{type} = 'text';
        if ($col->{money}) {
            $col->{class} = 'money';
            for my $row(@{$self->rows}){
                 if ( eval {$row->{$col->{col_id}}->can('to_output')}){
                    $row->{$col->{col_id}} = $row->{$col->{col_id}}->to_output(money => 1);
                 }
            }
        }
    }

    $template = LedgerSMB::Template->new(
        user => $LedgerSMB::App_State::User,
        locale => $self->locale,
        path => 'UI',
        no_auto_output => 1,
        template => $template,
        output_file => $name,
        format => (uc($format) || 'HTML'),
    );
    # needed to get aroud escaping of header line names
    # i.e. ignore_yearends -> ignore\_yearends
    # in latex
    my $replace_hnames = sub {
        my $lines = shift || [];
        my @newlines = map { { name => $_->{name} } } @{$self->header_lines};
        return [map { { %$_, %{shift @newlines} } } @$lines ];
    };
    my $company_name = LedgerSMB::Setting->get('company_name');
    warn "company_name:$company_name";
    $self->{cname} = $company_name;
    $self->{cnumber} = param('company');
    $self->{cnumber} =~ s/^ifg//;
    $template->render({report => $self,
                 company_name => $company_name,
                  companyname => $company_name,
              company_address => LedgerSMB::Setting->get('company_address'),
                      request => {nowtime => $self->{nowtime}},
                    new_heads => $replace_hnames,
                         name => $self->{report_name} // $self->name,
                       hlines => $self->header_lines,
                      columns => $columns,
                      nowtime => $self->{nowtime},
                    order_url => $self->order_url,
                      buttons => [],
                      options => [], gateway => 1,
                         rows => $self->rows});
   return $template;
}

package LedgerSMB::I18N;
no warnings 'redefine';
sub Text {
    return shift;
}

sub text {
    return shift;
}
