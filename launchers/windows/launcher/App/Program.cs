// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;
using Avalonia.Styling;

namespace S2Arm.Launcher;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args) => AppBuilder.Configure<LauncherApp>()
        .UsePlatformDetect().LogToTrace().StartWithClassicDesktopLifetime(args);
}

public sealed class LauncherApp : Application
{
    public override void Initialize()
    {
        RequestedThemeVariant = ThemeVariant.Dark;
        Styles.Add(new FluentTheme());
    }
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            desktop.MainWindow = new EnvironmentWindow();
        base.OnFrameworkInitializationCompleted();
    }
}
