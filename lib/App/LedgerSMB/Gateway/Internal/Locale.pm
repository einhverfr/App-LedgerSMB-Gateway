
package App::LedgerSMB::Gateway::Internal::Locale;
use LedgerSMB::App_State;

sub text {
    my ($self, @args) = @_;
    return join ', ', @args;
}

sub new {
    return bless {}, App::LedgerSMB::Gateway::Internal::Locale;
}

$LedgerSMB::App_State::Locale = new();
