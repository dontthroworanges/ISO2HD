using Microsoft.UI.Xaml.Controls;

namespace Iso2Hd;

/// <summary>The preferences form, shown in a <see cref="DialogWindow"/>.</summary>
public sealed partial class PreferencesPanel : UserControl
{
    private readonly AppSettings _settings;

    internal PreferencesPanel(AppSettings settings)
    {
        InitializeComponent();
        _settings = settings;

        VerifyToggle.IsOn = settings.Verify;
        BootToggle.IsOn = settings.BootPatch;
        ZeroToggle.IsOn = settings.ZeroRemainder;
        PadBox.Maximum = AppSettings.MaxPadSectors;
        PadBox.Value = settings.PadSectors;
        OutputToggle.IsOn = settings.ShowOutput;
    }

    /// <summary>Copies the form into the settings.</summary>
    public bool TryApply()
    {
        _settings.Verify = VerifyToggle.IsOn;
        _settings.BootPatch = BootToggle.IsOn;
        _settings.ZeroRemainder = ZeroToggle.IsOn;
        // An emptied box reads as NaN: no padding.
        _settings.PadSectors = double.IsNaN(PadBox.Value) ? 0 : (int)Math.Clamp(Math.Round(PadBox.Value), 0, AppSettings.MaxPadSectors);
        _settings.ShowOutput = OutputToggle.IsOn;
        return true;
    }
}
