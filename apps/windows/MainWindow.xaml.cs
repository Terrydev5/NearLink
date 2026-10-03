using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Diagnostics;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace NearLink.Windows;

public sealed partial class MainWindow : Window
{
    public MainViewModel ViewModel { get; }
    public MainWindow()
    {
        ViewModel = new(action => DispatcherQueue.TryEnqueue(() => action()));
        InitializeComponent();
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1040, 760));
        ViewModel.DevicesRefreshed += () =>
        {
            DeviceList.SelectedItem = ViewModel.Devices.FirstOrDefault(d => d.Id == ViewModel.SelectedID);
        };
        ViewModel.Conversation.CollectionChanged += (_, args) =>
        {
            if (args.NewItems?.Count > 0) Timeline.ScrollIntoView(args.NewItems[args.NewItems.Count - 1]);
        };
        Closed += async (_, _) =>
        {
            try { await ViewModel.DisposeAsync(); }
            catch (Exception error) { Debug.WriteLine(error); }
        };
        _ = ViewModel.StartAsync();
    }

    private void DeviceList_SelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        // Collection refresh may temporarily clear ListView selection; retain the stable selected ID.
        if (DeviceList.SelectedItem is DeviceRow row) ViewModel.Select(row.Id);
    }
    private async void Send_Click(object sender, RoutedEventArgs args) => await ViewModel.SendAsync();
    private void Refresh_Click(object sender, RoutedEventArgs args) => ViewModel.RefreshDiscovery();
    private void Notice_Closed(InfoBar sender, InfoBarClosedEventArgs args) => ViewModel.Notice = "";
    private async void Attach_Click(object sender, RoutedEventArgs args)
    {
        try
        {
            var picker = new FileOpenPicker();
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            picker.FileTypeFilter.Add("*");
            var files = await picker.PickMultipleFilesAsync();
            await ViewModel.SendFilesAsync(files.Select(file => file.Path));
        }
        catch (Exception error) { ViewModel.Notice = $"Could not select files: {error.Message}"; }
    }
    private async void Cancel_Click(object sender, RoutedEventArgs args)
    {
        if ((sender as Button)?.Tag is ConversationRow { TransferID: Guid id }) await ViewModel.CancelAsync(id);
    }
    private void OpenFile_Click(object sender, RoutedEventArgs args)
    {
        if ((sender as Button)?.Tag is not ConversationRow { LocalPath: string path }) return;
        if (!File.Exists(path)) { ViewModel.Notice = "This file was moved or deleted."; return; }
        Open(path);
    }
    private void OpenFolder_Click(object sender, RoutedEventArgs args) => Open(ViewModel.ReceiveDirectory);
    private void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception error) { ViewModel.Notice = $"Could not open this item: {error.Message}"; }
    }
}
