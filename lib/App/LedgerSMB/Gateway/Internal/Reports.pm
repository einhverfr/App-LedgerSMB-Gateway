package App::LedgerSMB::Gateway::Internal;
use App::LedgerSMB::Auth qw(authenticate);
#use lib "/home/ledgersmb/LedgerSMB/lib";
use lib "/opt/ledgersmb/";
use Try::Tiny;
use App::LedgerSMB::Gateway::Internal::Locale;
use LedgerSMB::Sysconfig;
use Log::Log4perl;
use Dancer ':syntax';
use Dancer::HTTP;
use Dancer::Serializer;
use Dancer::Response;
use Dancer::Plugin::Ajax;
use LedgerSMB::Report::BalanceSheet;
use LedgerSMB::Report::Aging;

prefix '/reports'
get '/balance_sheet/:date' => sub { to_json(balance_sheet(param('date')) };
get '/:class/aging' => sub { to_json(aging(param('class'))) };
get '/balance_sheet/:date/summary' => sub { to_json(bs_summary(param('date'))) };
get '/:class/aging/summary' => sub { to_json(aging_summary(param('class'))) };

sub balance_sheet {
    my ($date) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 0 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $report = LedgerSMB::Report::BalanceSheet->new(
          date_to => $date, legacy_hierarchy => 1
    );
    $report->run_report;
    return $report->rows();  
}

sub aging {
    my ($date) = @_;
    my $db = authenticate(
            host   => $LedgerSMB::Sysconfig::db_host,
            port   => $LedgerSMB::Sysconfig::db_port,
            dbname => param('company'),
    );
    local $LedgerSMB::App_State::DBH = $db->connect({AutoCommit => 0 });
    local $LedgerSMB::App_State::User = {numberformat => '1000.00'};
    my $report = LedgerSMB::Report::BalanceSheet->new(
          date_to => $date, legacy_hierarchy => 1
    );
    $report->run_report;
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
