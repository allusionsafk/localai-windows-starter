using System.Windows;

namespace AdaptiveMedia;

public partial class SettingsWindow : Window
{
    public AppSettings ResultSettings { get; private set; }

    public SettingsWindow(AppSettings settings)
    {
        InitializeComponent();
        ResultSettings = settings;
        HdrCheck.IsChecked = settings.AutoHdrSwitch;
        ExternalCheck.IsChecked = settings.PreferExternalDisplay;
        FullscreenCheck.IsChecked = settings.FullscreenExternal;
        BitstreamCheck.IsChecked = settings.HdmiBitstream;
        MpcCheck.IsChecked = settings.MpcFallback;
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        ResultSettings.AutoHdrSwitch = HdrCheck.IsChecked == true;
        ResultSettings.PreferExternalDisplay = ExternalCheck.IsChecked == true;
        ResultSettings.FullscreenExternal = FullscreenCheck.IsChecked == true;
        ResultSettings.HdmiBitstream = BitstreamCheck.IsChecked == true;
        ResultSettings.MpcFallback = MpcCheck.IsChecked == true;
        DialogResult = true;
    }
}
