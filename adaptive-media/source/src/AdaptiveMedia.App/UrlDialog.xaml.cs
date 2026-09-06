using System;
using System.Windows;
using System.Windows.Controls;

namespace AdaptiveMedia;

public partial class UrlDialog : Window
{
    public string MediaUrl { get; private set; } = "";
    public string? YtdlFormat { get; private set; }

    public UrlDialog() => InitializeComponent();

    private void Play_Click(object sender, RoutedEventArgs e)
    {
        if (!Uri.TryCreate(UrlBox.Text.Trim(), UriKind.Absolute, out var uri) ||
            !(uri.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase) || uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) ||
              uri.Scheme.Equals("rtsp", StringComparison.OrdinalIgnoreCase) || uri.Scheme.Equals("rtmp", StringComparison.OrdinalIgnoreCase)))
        {
            MessageBox.Show(this, "Enter a valid network media URL.", "Adaptive Media", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        MediaUrl = UrlBox.Text.Trim();
        if (QualityBox.SelectedItem is ComboBoxItem item)
            YtdlFormat = item.Tag?.ToString();
        DialogResult = true;
    }
}
