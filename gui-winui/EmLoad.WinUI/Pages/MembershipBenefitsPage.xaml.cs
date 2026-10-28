using EmLoad.WinUI.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace EmLoad.WinUI.Pages;

public sealed partial class MembershipBenefitsPage : Page
{
    public MembershipBenefitsPage()
    {
        InitializeComponent();
        var isPro = PatreonMembershipState.Tier == "Pro";
        TierTitle.Text = isPro ? "EmLoad Pro" : "EmLoad Plus";
        TierDescription.Text = isPro
            ? "EmLoad Pro includes the benefits from EmLoad Plus."
            : "Your Em Basic Patreon membership unlocks EmLoad Plus.";
        StoreBenefit.Visibility = isPro ? Visibility.Collapsed : Visibility.Visible;
        ProStoreNotice.Visibility = isPro ? Visibility.Visible : Visibility.Collapsed;
    }
}
