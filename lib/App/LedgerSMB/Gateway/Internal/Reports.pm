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

{
  no strict 'refs';
  my $to_json = sub($@) { my ($self) = @_; return $self->to_db() };
  *LedgerSMB::PGNumber::TO_JSON = $to_json;
  *LedgerSMB::PGDate::TO_JSON =  $to_json;
}

prefix '/lsmbgw/0.1/:company/internal/reports';
get '/balance_sheet/:date' => sub { to_json(balance_sheet(param('date'))) };
get '/:class/aging/:date' => sub { to_json(aging(param('class'), param('date') )) };
get '/balance_sheet/:date/summary' => sub { to_json(bs_summary(param('date'))) };
get '/:class/aging/:date/summary' => sub { to_json(aging_summary(param('class'), param('date'))) };

get '/pnl/:from_date/:to_date' => sub { to_json(pnl(param('from_date'), param('to_date'))) };

sub pnl {
    my ($from, $to) = @_;
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
          comparison_type => 'periods', basis => 'accrual', ignore_yearend => 'all'
    );
    $report->run_report;
    return {rows => $report->rheads->ids, display_order => $report->rheads->sort };  
}

sub balance_sheet {
    my ($date) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    $date = LedgerSMB::PGDate->from_db($date, 'date');
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $report = LedgerSMB::Report::Balance_Sheet->new(
          date_to => $date, legacy_hierarchy => 1
    );
    $report->run_report;
    return {rows => $report->rheads->ids, display_order => $report->rheads->sort };  
}

sub aging {
    my ($class, $date) = @_;
    my $eclass;
    if (lc $class eq 'ar'){
        $eclass = 2;
    } elsif (lc $class eq 'ap') {
        $eclass = 1;
    } else {
        die 'bad aging report.  needs to be ar or ap';
    }
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    $date = LedgerSMB::PGDate->from_db($date, 'date');
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 1 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $report = LedgerSMB::Report::Aging->new(
          date_to => $date, entity_class => $eclass, report_type => 'summary', to_date => $date
    );
    eval { $report->run_report };
    return $report->rows();  
}

sub bs_summary {
    my ($date) = @_;
    my $rows = balance_sheet($date);
}

sub aging_summary {
    my ($date) = @_;
    my $rows = aging($date);
}
