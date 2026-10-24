using System.Text.Json;
using EmLoad.WinUI.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace EmLoad.WinUI.Pages;

public sealed partial class DiagnosticsPage : Page
{
    private AppState State => App.Current.State;

    public DiagnosticsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await RunAsync();
    }

    private async void Run_Click(object sender, RoutedEventArgs e) => await RunAsync();

    private async Task RunAsync()
    {
        if (State.Engine is null)
        {
            return;
        }

        Busy.IsActive = true;
        SummaryText.Text = "Running checks…";
        ChecksHost.Children.Clear();

        try
        {
            var result = await State.Engine.CallAsync("doctor.check");
            var checks = result.ValueKind == JsonValueKind.Array
                ? result.EnumerateArray().Select(Models.Check).ToList()
                : new List<DoctorCheck>();

            ChecksHost.Children.Clear();
            foreach (var check in checks)
            {
                ChecksHost.Children.Add(Row(check));
            }

            var errors = checks.Count(c => c.Status == "error");
            var warnings = checks.Count(c => c.Status == "warn");
            SummaryText.Text = errors == 0 && warnings == 0
                ? "All checks passed"
                : $"{errors} error(s), {warnings} warning(s)";
            MainWindow.Shell.SetStatus(SummaryText.Text);
        }
        catch (EngineException exc)
        {
            SummaryText.Text = $"Could not run diagnostics: {exc.Message}";
            ChecksHost.Children.Add(new TextBlock
            {
                Text = exc.Message,
                TextWrapping = TextWrapping.Wrap,
                Foreground = Brush("SystemFillColorCriticalBrush"),
            });
        }
        finally
        {
            Busy.IsActive = false;
        }
    }

    private UIElement Row(DoctorCheck check)
    {
        var grid = new Grid { ColumnSpacing = 10, Padding = new Thickness(0, 6, 0, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var glyph = new TextBlock
        {
            Text = check.Glyph,
            FontSize = 15,
            VerticalAlignment = VerticalAlignment.Top,
            Foreground = Brush(check.Status switch
            {
                "ok" => "SystemFillColorSuccessBrush",
                "warn" => "SystemFillColorCautionBrush",
                "error" => "SystemFillColorCriticalBrush",
                _ => "TextFillColorSecondaryBrush",
            }),
        };
        Grid.SetColumn(glyph, 0);
        grid.Children.Add(glyph);

        var name = new TextBlock
        {
            Text = check.Name,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        };
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);

        var message = new TextBlock
        {
            Text = check.Message,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Foreground = Brush("TextFillColorSecondaryBrush"),
        };
        Grid.SetColumn(message, 2);
        grid.Children.Add(message);

        return grid;
    }

    private static Brush Brush(string resourceKey) =>
        (Brush)Application.Current.Resources[resourceKey];
}
