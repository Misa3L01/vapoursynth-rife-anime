#Requires -Version 5.1
<#
    interpolar-app.ps1 - Interfaz grafica de la cola de interpolacion.

    Es una capa delgada: arma la cola y llama a scripts\process-one.bat por cada
    video, igual que run.bat y la cola de Miku. Toda la logica de render vive en
    process-one.bat e interpolate.vpy; aca no se duplica nada.

    Expone solo los parametros que las mediciones mostraron que cambian algo.
    NVENC, num_streams, cuda_graph, dither y el resto quedan en config.bat.

    Se abre con Interpolar.bat o con el acceso directo Interpolar.lnk.
#>
param([switch]$NoShow)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not ('VsApp.VideoItem' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace VsApp {
    public class VideoItem : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        void Notify(string p) {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(p));
        }
        bool selected, editable = true;
        string durationText = "...", note = "", status = "";

        public string Path { get; set; }
        public string Name { get; set; }
        public string BaseName { get; set; }
        public string SizeText { get; set; }
        public string Codec { get; set; }
        public double Duration { get; set; }
        public double Fps { get; set; }
        public bool Probed { get; set; }

        public bool Selected { get { return selected; } set { if (selected != value) { selected = value; Notify("Selected"); } } }
        public bool Editable { get { return editable; } set { if (editable != value) { editable = value; Notify("Editable"); } } }
        public string DurationText { get { return durationText; } set { if (durationText != value) { durationText = value; Notify("DurationText"); } } }
        public string Note { get { return note; } set { if (note != value) { note = value; Notify("Note"); } } }
        public string Status { get { return status; } set { if (status != value) { status = value; Notify("Status"); } } }
    }

    public static class Native {
        [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

        // ES_CONTINUOUS | ES_SYSTEM_REQUIRED: evita que la laptop se suspenda a
        // mitad de una cola de varias horas. La pantalla si puede apagarse.
        public static void KeepAwake(bool on) { SetThreadExecutionState(on ? 0x80000001u : 0x80000000u); }

        // Sin esto WPF se escala como bitmap y el texto sale borroso con 125-150 %.
        public static void DpiAware() { try { SetProcessDPIAware(); } catch { } }

        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 20H1+ y 11); 19 en builds previos.
        // SetWindowPos con FRAMECHANGED hace que el marco se redibuje en el acto.
        public static void DarkTitle(IntPtr hwnd, bool dark) {
            int v = dark ? 1 : 0;
            if (DwmSetWindowAttribute(hwnd, 20, ref v, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref v, 4);
            SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020);
        }
    }
}
'@
}
[VsApp.Native]::DpiAware()

# ============================================================== rutas / config
$Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ConfigBat = Join-Path $Root 'config.bat'
$PresetDir = Join-Path $Root 'presets'
$ModelDir  = Join-Path $Root 'Python\plugins64\models'
$Exts      = @('.mkv', '.mp4', '.m2ts', '.avi', '.webm')
$Inv       = [Globalization.CultureInfo]::InvariantCulture

# Lee las lineas  set "CLAVE=valor"  de un .bat y expande %VARIABLES% ya vistas.
# Asi config.bat y los presets siguen siendo la unica fuente de verdad.
function Read-BatVars([string]$File, [hashtable]$Seed = @{}) {
    $vars = @{}
    foreach ($k in $Seed.Keys) { $vars[$k] = $Seed[$k] }
    if (-not (Test-Path -LiteralPath $File)) { return $vars }
    foreach ($line in [System.IO.File]::ReadAllLines($File)) {
        if ($line -notmatch '^\s*set\s+"([A-Za-z_]\w*)=(.*)"\s*$') { continue }
        $k = $Matches[1]; $v = $Matches[2]
        if ($v -like '*%~*' -or $Seed.ContainsKey($k)) { continue }
        $v = [regex]::Replace($v, '%(\w+)%', {
            param($m)
            $n = $m.Groups[1].Value
            if ($vars.ContainsKey($n)) { $vars[$n] } else { $m.Value }
        })
        $vars[$k] = $v
    }
    $vars
}

$Cfg       = Read-BatVars $ConfigBat @{ VS_ROOT = $Root }
$InputDir  = if ($Cfg.INPUT_DIR)  { $Cfg.INPUT_DIR }  else { Join-Path $Root 'videos' }
$OutputDir = if ($Cfg.OUTPUT_DIR) { $Cfg.OUTPUT_DIR } else { Join-Path $Root 'output' }
$WorkDir   = if ($Cfg.WORK_DIR)   { $Cfg.WORK_DIR }   else { Join-Path $Root 'cache\work' }
$ProcBat   = Join-Path $Root 'scripts\process-one.bat'
$JobBat    = Join-Path $WorkDir 'app-job.bat'
$BaseSuffix = if ($Cfg.OUT_SUFFIX) { $Cfg.OUT_SUFFIX } else { '-2x' }
$Required  = @($Cfg.VSPIPE, $Cfg.FFMPEG, $Cfg.FFPROBE, $ProcBat, $ConfigBat)

# ===================================================================== XAML
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Interpolar" Width="820" Height="800" MinWidth="740" MinHeight="660"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Bg}"
        FontFamily="Segoe UI" FontSize="13" Foreground="{DynamicResource Text}"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <!-- Los colores (Bg, Card, Text, Accent...) los carga Set-Theme al arrancar y
         al cambiar de tema. Todo los usa con DynamicResource para poder cambiar
         sin reabrir la ventana.
         Los controles nativos de WPF ignoran esos colores y se dibujan con el
         tema del sistema (en oscuro quedarian bloques blancos), por eso cada uno
         tiene su plantilla propia. -->

    <Style x:Key="CardStyle" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource Card}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16,14"/>
    </Style>
    <Style x:Key="Cap" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Margin" Value="0,0,0,5"/>
    </Style>
    <Style x:Key="Val" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Width" Value="40"/>
      <Setter Property="TextAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- tooltip -->
    <Style TargetType="ToolTip">
      <Setter Property="MaxWidth" Value="380"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{DynamicResource Popup}" BorderBrush="{DynamicResource ControlBorder}"
                    BorderThickness="1" CornerRadius="6" Padding="10,7">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Setter Property="ContentTemplate">
        <Setter.Value>
          <DataTemplate><TextBlock Text="{Binding}" TextWrapping="Wrap" LineHeight="18"/></DataTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- botones: una capa encima que se aclara u oscurece al pasar el mouse,
         asi el hover funciona sobre cualquier color y en ambos temas -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="{DynamicResource Control}"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ControlBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"/>
              <Border x:Name="h" Background="{DynamicResource HoverOverlay}" CornerRadius="6" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="h" Property="Opacity" Value="1"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="h" Property="Opacity" Value="1"/><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="Foreground" Value="{DynamicResource OnAccent}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,9"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="{DynamicResource Danger}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource DangerBorder}"/>
      <Setter Property="Padding" Value="18,9"/>
    </Style>

    <!-- combo -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Padding="10,6" Margin="4,1" CornerRadius="4" Background="Transparent">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource RowHover}"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource RowSelected}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="{DynamicResource Control}" BorderBrush="{DynamicResource ControlBorder}"
                            BorderThickness="1" CornerRadius="6">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,1,11,0"
                            Data="M 0 0 L 4 4 L 8 0" Stroke="{DynamicResource Muted}" StrokeThickness="1.5"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Margin="10,0,30,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                TextElement.Foreground="{DynamicResource Text}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border Background="{DynamicResource Popup}" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1"
                        CornerRadius="6" Margin="0,4,0,0" Padding="0,4"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                  <ScrollViewer MaxHeight="{TemplateBinding MaxDropDownHeight}">
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- slider -->
    <Style TargetType="Slider">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="IsSnapToTickEnabled" Value="True"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Height="22" Background="Transparent">
              <Border Height="4" CornerRadius="2" Background="{DynamicResource Track}" VerticalAlignment="Center" Margin="7,0"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Grid Background="Transparent">
                          <Border Height="4" CornerRadius="2" Background="{DynamicResource Accent}" VerticalAlignment="Center" Margin="7,0,-2,0"/>
                        </Grid>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Grid Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse x:Name="E" Width="14" Height="14" Fill="{DynamicResource Accent}"
                                 Stroke="{DynamicResource Card}" StrokeThickness="2"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="E" Property="Fill" Value="{DynamicResource AccentHover}"/></Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- checkbox y radio -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="16" Height="16" CornerRadius="4" BorderThickness="1.5" VerticalAlignment="Center"
                      BorderBrush="{DynamicResource ControlBorder}" Background="{DynamicResource Control}">
                <Path x:Name="Mark" Data="M 0 4 L 3.5 7.5 L 9.5 1" Stroke="{DynamicResource OnAccent}" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                      HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter x:Name="Cp" Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="Content" Value="{x:Null}"><Setter TargetName="Cp" Property="Margin" Value="0"/></Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="16" Height="16" VerticalAlignment="Center">
                <Ellipse x:Name="Ring" Stroke="{DynamicResource ControlBorder}" StrokeThickness="1.5" Fill="{DynamicResource Control}"/>
                <Ellipse x:Name="Dot" Width="8" Height="8" Fill="{DynamicResource Accent}" Visibility="Collapsed"/>
              </Grid>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ring" Property="Stroke" Value="{DynamicResource Accent}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Ring" Property="Stroke" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- barras de progreso, con animacion propia para el modo indeterminado -->
    <Style TargetType="ProgressBar">
      <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
      <Setter Property="Background" Value="{DynamicResource Track}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="5" ClipToBounds="True">
              <Grid ClipToBounds="True">
                <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="5"/>
                <Border x:Name="Glow" Width="140" HorizontalAlignment="Left" CornerRadius="5" Visibility="Collapsed"
                        Background="{TemplateBinding Foreground}">
                  <Border.RenderTransform><TranslateTransform X="-140"/></Border.RenderTransform>
                </Border>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsIndeterminate" Value="True">
                <Setter TargetName="PART_Indicator" Property="Visibility" Value="Collapsed"/>
                <Setter TargetName="Glow" Property="Visibility" Value="Visible"/>
                <Trigger.EnterActions>
                  <BeginStoryboard x:Name="Sweep">
                    <Storyboard RepeatBehavior="Forever">
                      <DoubleAnimation Storyboard.TargetName="Glow"
                                       Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"
                                       From="-140" To="900" Duration="0:0:1.6"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions><StopStoryboard BeginStoryboardName="Sweep"/></Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- lista: filas, encabezados y barras de scroll -->
    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListViewItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="0,5" Margin="0,1">
              <GridViewRowPresenter Content="{TemplateBinding Content}" Columns="{TemplateBinding GridView.ColumnCollection}"
                                    VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource RowHover}"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource RowSelected}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridViewColumnHeader">
            <Grid>
              <Border Background="{DynamicResource Card}" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,0,1" Padding="7,6">
                <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
              </Border>
              <Thumb x:Name="PART_HeaderGripper" HorizontalAlignment="Right" Width="8" Margin="0,0,-4,0" Cursor="SizeWE">
                <Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="Transparent"/></ControlTemplate></Thumb.Template>
              </Thumb>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PageBtn" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScrollThumbStyle" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="T" Background="{DynamicResource ScrollThumb}" CornerRadius="4" Margin="2"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{DynamicResource Muted}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource PageBtn}"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource PageBtn}"/></Track.IncreaseRepeatButton>
              <Track.Thumb><Thumb Style="{StaticResource ScrollThumbStyle}"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track">
                  <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageLeftCommand" Style="{StaticResource PageBtn}"/></Track.DecreaseRepeatButton>
                  <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageRightCommand" Style="{StaticResource PageBtn}"/></Track.IncreaseRepeatButton>
                  <Track.Thumb><Thumb Style="{StaticResource ScrollThumbStyle}"/></Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid Margin="18,14,18,16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- encabezado -->
    <DockPanel Grid.Row="0" Margin="2,0,0,12">
      <Button x:Name="BtnTheme" DockPanel.Dock="Right" Style="{StaticResource Btn}" Padding="11,5" VerticalAlignment="Center"
              ToolTip="Cambiar entre tema claro y oscuro. La elección se recuerda.">
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="TxThemeIcon" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13"
                     VerticalAlignment="Center" Margin="0,1,8,0"/>
          <TextBlock x:Name="TxThemeLabel" FontSize="12" VerticalAlignment="Center"/>
        </StackPanel>
      </Button>
      <!-- ver en tiempo real: independiente de la cola, no genera archivos -->
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" Margin="0,0,14,0" VerticalAlignment="Center">
        <ComboBox x:Name="CbLiveFps" Width="126" Margin="0,0,6,0" VerticalAlignment="Center"
                  ToolTip="Fotogramas por segundo al ver en tiempo real.&#10;48 fps (×2): para monitores de 144 y 240 Hz. En 144 Hz cada frame dura justo 3 refrescos.&#10;60 fps (×2.5): para monitores de 60 y 120 Hz. Esta GPU no llega a 60 fps en 1080p: interpola a 720p y mpv lo lleva a pantalla completa."/>
        <Button x:Name="BtnLive" Content="&#x25B6;  Ver en tiempo real" Style="{StaticResource Btn}" Padding="12,5"
                ToolTip="Abre en mpv el video marcado en la lista (clic sobre su nombre), interpolado en vivo con RIFE. No genera ningún archivo.&#10;Sin ninguno marcado, usa el primero tildado, o te deja elegir un archivo.&#10;&#10;En mpv: Ctrl+I prende y apaga la interpolación para comparar con el original. I muestra los fps y los frames perdidos.&#10;&#10;La primera vez con una resolución nueva, TensorRT tarda unos 2 minutos en prepararse."/>
        <Button x:Name="BtnLiveOpen" Content="Abrir…" Style="{StaticResource Btn}" Padding="10,5" Margin="6,0,0,0"
                ToolTip="Elegí cualquier video del disco para verlo en tiempo real."/>
      </StackPanel>
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="Interpolar" FontSize="21" FontWeight="SemiBold"/>
        <TextBlock Text="RIFE · TensorRT" Foreground="{DynamicResource Muted}" VerticalAlignment="Bottom" Margin="10,0,0,4"/>
      </StackPanel>
    </DockPanel>

    <!-- opciones -->
    <Border Grid.Row="1" Style="{StaticResource CardStyle}">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="18"/>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="18"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="14"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="14"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Grid.Column="0">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="Preset" Style="{StaticResource Cap}"/>
            <TextBlock x:Name="TxPresetState" Style="{StaticResource Cap}" Foreground="{DynamicResource Accent}" Margin="6,0,0,5"/>
          </StackPanel>
          <ComboBox x:Name="CbPreset" ToolTip="Carga valores medidos en esta PC. Después podés ajustar cualquier control a mano."/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="2">
          <TextBlock Text="Modelo" Style="{StaticResource Cap}"/>
          <ComboBox x:Name="CbModel" ToolTip="4.16 lite: 30 % más rápido, con calidad empatada en las 3 fuentes medidas.&#10;4.26: VMAF +0.3 a cambio de ser 38 % más lento."/>
        </StackPanel>
        <StackPanel Grid.Row="0" Grid.Column="4">
          <TextBlock Text="FPS de salida" Style="{StaticResource Cap}"/>
          <ComboBox x:Name="CbFps" ToolTip="×2 conserva todos los frames originales y agrega uno en el medio: la mejor calidad.&#10;×2.5 da 59.94 fps: se ve más fluido en un monitor de 60 Hz, pero solo 1 de cada 5 frames es original."/>
        </StackPanel>

        <StackPanel Grid.Row="2" Grid.Column="0">
          <TextBlock Text="Detección de cortes" Style="{StaticResource Cap}"/>
          <DockPanel>
            <TextBlock x:Name="TxCut" DockPanel.Dock="Right" Style="{StaticResource Val}" Text="{Binding Value, ElementName=SlCut, StringFormat={}{0:0.00}}"/>
            <Slider x:Name="SlCut" Minimum="0.05" Maximum="0.40" TickFrequency="0.01" Value="0.20"
                    ToolTip="Umbral de cambio de plano. En cada corte RIFE copia el frame en vez de inventar uno.&#10;0.20 dio la mejor calidad medida.&#10;Más bajo es más rápido, pero duplica frames que se podían interpolar y aparece un leve tironeo."/>
          </DockPanel>
        </StackPanel>
        <StackPanel Grid.Row="2" Grid.Column="2">
          <TextBlock Text="Calidad CQ  (menor = mejor)" Style="{StaticResource Cap}"/>
          <DockPanel>
            <TextBlock x:Name="TxCq" DockPanel.Dock="Right" Style="{StaticResource Val}" Text="{Binding Value, ElementName=SlCq, StringFormat={}{0:0}}"/>
            <Slider x:Name="SlCq" Minimum="14" Maximum="26" TickFrequency="1" Value="20"
                    ToolTip="Calidad del encoder. Menos es mejor calidad y archivo más grande. Entre 18 y 20 es prácticamente transparente."/>
          </DockPanel>
        </StackPanel>
        <StackPanel Grid.Row="2" Grid.Column="4">
          <TextBlock Text="Nitidez (CAS)" Style="{StaticResource Cap}"/>
          <DockPanel>
            <TextBlock x:Name="TxCas" DockPanel.Dock="Right" Style="{StaticResource Val}" Text="{Binding Value, ElementName=SlCas, StringFormat={}{0:0.00}}"/>
            <Slider x:Name="SlCas" Minimum="0" Maximum="0.80" TickFrequency="0.05" Value="0.35"
                    ToolTip="Afilado adaptativo, solo sobre la luma para no generar flecos de color. 0 lo desactiva."/>
          </DockPanel>
        </StackPanel>

        <StackPanel Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="3">
          <TextBlock Text="Destino" Style="{StaticResource Cap}"/>
          <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
            <RadioButton x:Name="RbOut" GroupName="dest" IsChecked="True" Margin="0,0,22,0"/>
            <RadioButton x:Name="RbSame" GroupName="dest" Content="junto al original"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Row="4" Grid.Column="4">
          <TextBlock Text="Extra" Style="{StaticResource Cap}"/>
          <CheckBox x:Name="ChkDeband" Content="Deband (degradados)" Margin="0,3,0,0"
                    ToolTip="Suaviza el banding en cielos, degradados y fundidos. Cuesta algo de velocidad."/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- estado de la GPU -->
    <Border Grid.Row="2" Margin="0,10,0,10" Padding="12,8" CornerRadius="6" Background="{DynamicResource Card}"
            BorderBrush="{DynamicResource Line}" BorderThickness="1">
      <DockPanel>
        <Ellipse x:Name="GpuDot" Width="9" Height="9" Fill="DarkGray" Margin="0,0,9,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="TxGpu" Text="GPU: consultando…" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
    </Border>

    <!-- lista de videos -->
    <Border Grid.Row="3" Style="{StaticResource CardStyle}" Padding="0">
      <DockPanel>
        <TextBlock x:Name="TxInput" DockPanel.Dock="Top" Style="{StaticResource Cap}" Margin="14,10,14,4" TextTrimming="CharacterEllipsis"/>
        <DockPanel DockPanel.Dock="Bottom" Margin="12,8,12,10" LastChildFill="False">
          <Button x:Name="BtnAll" Content="Todos" Style="{StaticResource Btn}" Margin="0,0,6,0"/>
          <Button x:Name="BtnNone" Content="Ninguno" Style="{StaticResource Btn}"/>
          <TextBlock x:Name="TxSelInfo" VerticalAlignment="Center" Margin="12,0,0,0" Foreground="{DynamicResource Muted}"/>
          <Button x:Name="BtnRefresh" Content="&#x21BB;  Refrescar" Style="{StaticResource Btn}" DockPanel.Dock="Right"/>
        </DockPanel>
        <Border DockPanel.Dock="Bottom" Height="1" Background="{DynamicResource Line}"/>
        <Grid>
          <ListView x:Name="LvVideos" BorderThickness="0" Margin="6,0,6,0"
                    Background="{DynamicResource Card}" Foreground="{DynamicResource Text}">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="34">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                IsEnabled="{Binding Editable}" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="Video" Width="290">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <TextBlock Text="{Binding Name}" ToolTip="{Binding Path}" TextTrimming="CharacterEllipsis"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
                <GridViewColumn Header="Duración" Width="70" DisplayMemberBinding="{Binding DurationText}"/>
                <GridViewColumn Header="Tamaño" Width="72" DisplayMemberBinding="{Binding SizeText}"/>
                <GridViewColumn Header="Nota" Width="96" DisplayMemberBinding="{Binding Note}"/>
                <GridViewColumn Header="Estado" Width="160">
                  <GridViewColumn.CellTemplate>
                    <DataTemplate>
                      <TextBlock Text="{Binding Status}" ToolTip="{Binding Status}" TextTrimming="CharacterEllipsis"/>
                    </DataTemplate>
                  </GridViewColumn.CellTemplate>
                </GridViewColumn>
              </GridView>
            </ListView.View>
          </ListView>
          <TextBlock x:Name="TxEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" TextAlignment="Center"
                     Foreground="{DynamicResource Muted}" Visibility="Collapsed"/>
        </Grid>
      </DockPanel>
    </Border>

    <!-- progreso -->
    <Border Grid.Row="4" Style="{StaticResource CardStyle}" Margin="0,10,0,0">
      <StackPanel>
        <DockPanel>
          <TextBlock x:Name="TxCurPct" DockPanel.Dock="Right" FontWeight="SemiBold" Margin="12,0,0,0"/>
          <TextBlock x:Name="TxCurName" Text="Listo para empezar" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
        <ProgressBar x:Name="PbCur" Height="10" Margin="0,9,0,8" Maximum="100"/>
        <DockPanel>
          <TextBlock x:Name="TxEta" DockPanel.Dock="Right" Foreground="{DynamicResource Muted}" VerticalAlignment="Center"/>
          <TextBlock x:Name="TxSpeed" FontSize="14.5" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"
                     TextTrimming="CharacterEllipsis"/>
        </DockPanel>
        <Border Height="1" Background="{DynamicResource Line}" Margin="0,12,0,10"/>
        <DockPanel>
          <TextBlock x:Name="TxQueue" DockPanel.Dock="Right" Foreground="{DynamicResource Muted}" Margin="12,0,0,0"
                     VerticalAlignment="Center" MinWidth="170" TextAlignment="Right"/>
          <TextBlock Text="Cola" Width="40" VerticalAlignment="Center" Foreground="{DynamicResource Muted}"/>
          <ProgressBar x:Name="PbQueue" Height="6" Foreground="{DynamicResource Good}" VerticalAlignment="Center" Maximum="100"/>
        </DockPanel>
      </StackPanel>
    </Border>

    <!-- acciones -->
    <DockPanel Grid.Row="5" Margin="0,12,0,0" LastChildFill="False">
      <TextBlock x:Name="TxFooter" VerticalAlignment="Center" Foreground="{DynamicResource Muted}"
                 TextTrimming="CharacterEllipsis" MaxWidth="450"/>
      <Button x:Name="BtnStart" Content="&#x25B6;  Iniciar cola" Style="{StaticResource BtnPrimary}" DockPanel.Dock="Right"/>
      <Button x:Name="BtnCancel" Content="Cancelar" Style="{StaticResource BtnDanger}" DockPanel.Dock="Right"
              Margin="0,0,8,0" IsEnabled="False"/>
    </DockPanel>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($n in 'TxPresetState', 'CbPreset', 'CbModel', 'CbFps', 'SlCut', 'SlCq', 'SlCas', 'RbOut', 'RbSame',
               'ChkDeband', 'GpuDot', 'TxGpu', 'TxInput', 'LvVideos', 'TxEmpty', 'BtnAll', 'BtnNone',
               'BtnRefresh', 'TxSelInfo', 'TxCurName', 'TxCurPct', 'PbCur', 'TxSpeed', 'TxEta',
               'PbQueue', 'TxQueue', 'BtnCancel', 'BtnStart', 'TxFooter', 'BtnTheme', 'TxThemeIcon', 'TxThemeLabel',
               'CbLiveFps', 'BtnLive', 'BtnLiveOpen') {
    $ui[$n] = $window.FindName($n)
}

# ==================================================================== estado
$S = @{
    Running = $false; Cancelling = $false
    Queue = @(); Index = 0; Ok = 0; Fail = 0; QueueStart = $null
    Job = $null; Suffix = $BaseSuffix; MultiValue = 2.0
    ProbeProc = $null; ProbeItem = $null
    GpuProc = $null; Gpu = $null; GpuWait = 0
    PresetValues = $null; BasePreset = 'balanced'; TickError = $false; Theme = 'light'
    Live = $null
}
$Items = New-Object 'System.Collections.ObjectModel.ObservableCollection[VsApp.VideoItem]'
$ui.LvVideos.ItemsSource = $Items

$Brush = @{
    Green = [Windows.Media.Brushes]::MediumSeaGreen
    Amber = [Windows.Media.Brushes]::Orange
    Gray  = [Windows.Media.Brushes]::DarkGray
    Blue  = [Windows.Media.Brushes]::RoyalBlue
}

# =================================================================== helpers
function Format-Size([double]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } else { '{0:N0} MB' -f ($b / 1MB) }
}

function Format-Time([double]$sec) {
    if ([double]::IsNaN($sec) -or [double]::IsInfinity($sec) -or $sec -lt 0) { return '-' }
    $t = [TimeSpan]::FromSeconds([math]::Round($sec))
    if ($t.TotalHours -ge 1) { '{0}:{1:D2}:{2:D2}' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds }
    else { '{0}:{1:D2}' -f $t.Minutes, $t.Seconds }
}

function Get-Num([string]$s) {
    $d = 0.0
    if ([double]::TryParse($s.Trim(), [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { $d } else { $null }
}

function Get-Rate([string]$s) {
    if ($s -match '^\s*(\d+)\s*/\s*(\d+)\s*$' -and [double]$Matches[2] -gt 0) { [double]$Matches[1] / [double]$Matches[2] }
    else { Get-Num $s }
}

function Start-Hidden([string]$Exe, [string]$ArgLine, [switch]$Capture, [hashtable]$Env) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $ArgLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $Root
    if ($Capture) {
        $psi.RedirectStandardOutput = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    }
    if ($Env) { foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] } }
    [System.Diagnostics.Process]::Start($psi)
}

function Write-AppLog([string]$Msg) {
    try {
        if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $WorkDir 'app-errores.log') -Value ('{0:u}  {1}' -f (Get-Date), $Msg) -Encoding UTF8
    } catch { }
}

function Invoke-Safe([scriptblock]$Block) {
    try { & $Block }
    catch {
        Write-AppLog ($_ | Out-String)
        Show-Message ("Error inesperado:`n`n" + $_.Exception.Message) 'Error'
    }
}

# ==================================================================== tema
# Cada clave es un recurso que la ventana usa con DynamicResource. Cambiar de
# tema es reemplazar estos pinceles; WPF redibuja todo solo.
$Palettes = @{
    light = @{
        Bg = '#F1F3F6'; Card = '#FFFFFF'; Line = '#E5E7EB'; Text = '#1F2937'; Muted = '#6B7280'
        Accent = '#2563EB'; AccentHover = '#1D4ED8'; OnAccent = '#FFFFFF'
        Control = '#FFFFFF'; ControlBorder = '#D1D5DB'; Popup = '#FFFFFF'; Track = '#E5E7EB'
        RowHover = '#F3F4F6'; RowSelected = '#DBEAFE'; ScrollThumb = '#C4C9D2'
        HoverOverlay = '#12000000'; Danger = '#B91C1C'; DangerBorder = '#FCA5A5'; Good = '#10B981'
    }
    dark = @{
        Bg = '#0F1115'; Card = '#181B22'; Line = '#262B35'; Text = '#E6E8EC'; Muted = '#9AA3B2'
        Accent = '#3B82F6'; AccentHover = '#60A5FA'; OnAccent = '#FFFFFF'
        Control = '#1F232B'; ControlBorder = '#363C48'; Popup = '#1F232B'; Track = '#2A2F3A'
        RowHover = '#212631'; RowSelected = '#1D3557'; ScrollThumb = '#3A404C'
        HoverOverlay = '#1AFFFFFF'; Danger = '#F87171'; DangerBorder = '#7F1D1D'; Good = '#10B981'
    }
}

# La preferencia vive en cache\ para que viaje con la carpeta. cleanup.ps1 solo
# limpia cache\lwi y cache\work, asi que no la borra.
$SettingsFile = Join-Path $Root 'cache\app-settings.json'

function Read-Settings {
    try { Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

function Save-Settings {
    try {
        $dir = Split-Path -Parent $SettingsFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [pscustomobject]@{ Theme = $S.Theme; LiveFps = (Get-LiveFps) } | ConvertTo-Json |
            Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch { Write-AppLog ("No se pudo guardar la configuracion: " + $_.Exception.Message) }
}

# Sin preferencia guardada, sigue el modo de apps de Windows.
function Get-SystemTheme {
    try {
        $v = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme'
        if ($v -eq 0) { 'dark' } else { 'light' }
    } catch { 'light' }
}

function New-Brush([string]$Hex) {
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    $b
}

function Set-Theme([string]$Name) {
    if (-not $Palettes.ContainsKey($Name)) { $Name = 'light' }
    $pal = $Palettes[$Name]
    # El cast importa: lo que devuelve una funcion de PowerShell sale envuelto en
    # un PSObject, y ResourceDictionary (que acepta object) guardaria el envoltorio.
    foreach ($k in $pal.Keys) { $window.Resources[$k] = [System.Windows.Media.Brush](New-Brush $pal[$k]) }
    $S.Theme = $Name

    # El boton muestra a que tema se pasa, no el actual.
    if ($Name -eq 'dark') { $ui.TxThemeIcon.Text = [string][char]0xE706; $ui.TxThemeLabel.Text = 'Claro' }
    else                  { $ui.TxThemeIcon.Text = [string][char]0xE708; $ui.TxThemeLabel.Text = 'Oscuro' }

    # La barra de titulo la dibuja Windows, no WPF: hay que pedirla oscura aparte.
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).EnsureHandle()
        [VsApp.Native]::DarkTitle($hwnd, $Name -eq 'dark')
    } catch { }
}

# ================================================================ dialogos
# Dialogos propios en vez de MessageBox: el de Windows no se puede oscurecer y
# quedaria un cartel blanco en medio de la app.
$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        SizeToContent="WidthAndHeight" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Foreground="{DynamicResource Text}"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Border Background="{DynamicResource Card}" BorderBrush="{DynamicResource ControlBorder}" BorderThickness="1"
          CornerRadius="10" Padding="24,20,24,18" Margin="18">
    <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="3" Opacity="0.35"/></Border.Effect>
    <StackPanel Width="420">
      <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
        <Ellipse x:Name="Dot" Width="10" Height="10" VerticalAlignment="Center" Margin="0,1,10,0"/>
        <TextBlock x:Name="Head" FontSize="15" FontWeight="SemiBold"/>
      </StackPanel>
      <TextBlock x:Name="Body" TextWrapping="Wrap" LineHeight="20"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
        <Button x:Name="BtnNo" Content="No" Style="{DynamicResource Btn}" Margin="0,0,8,0" MinWidth="84" IsCancel="True"/>
        <Button x:Name="BtnYes" Content="Aceptar" Style="{DynamicResource BtnPrimary}" MinWidth="96" IsDefault="True"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

# Se arma aparte de Show-Dialog para poder renderizarlo en las pruebas.
function New-Dialog([string]$Msg, [string]$Kind = 'info', [switch]$YesNo) {
    $d = [Windows.Markup.XamlReader]::Parse($dialogXaml)
    foreach ($k in @($window.Resources.Keys)) { $d.Resources[$k] = $window.Resources[$k] }
    if ($window.IsVisible) { $d.Owner = $window } else { $d.WindowStartupLocation = 'CenterScreen' }

    $head = $d.FindName('Head'); $dot = $d.FindName('Dot')
    switch ($Kind) {
        'warn'  { $head.Text = 'Atención';   $dot.Fill = $Brush.Amber }
        'error' { $head.Text = 'Error';      $dot.Fill = [Windows.Media.Brushes]::IndianRed }
        default { $head.Text = 'Interpolar'; $dot.Fill = $window.Resources['Accent'] }
    }
    $d.FindName('Body').Text = $Msg

    $yes = $d.FindName('BtnYes'); $no = $d.FindName('BtnNo')
    if ($YesNo) { $yes.Content = 'Sí' }
    else { $no.Visibility = 'Collapsed'; $yes.IsCancel = $true }

    $res = @{ Yes = $false }
    $yes.add_Click({ $res.Yes = $true; $d.Close() }.GetNewClosure())
    $d.add_MouseLeftButtonDown({ try { $d.DragMove() } catch { } }.GetNewClosure())
    @{ Window = $d; Result = $res }
}

function Show-Dialog([string]$Msg, [string]$Kind = 'info', [switch]$YesNo) {
    # Mientras hay un dialogo modal el dispatcher sigue disparando el timer; se
    # pausa para que la cola no avance por detras de una pregunta.
    $timer.Stop()
    try {
        $dlg = New-Dialog $Msg $Kind -YesNo:$YesNo
        [void]$dlg.Window.ShowDialog()
        $dlg.Result.Yes
    } finally { $timer.Start() }
}

function Ask([string]$Msg) { Show-Dialog $Msg 'warn' -YesNo }

function Show-Message([string]$Msg, [string]$Icon = 'Information') {
    $kind = if ($Icon -eq 'Error') { 'error' } else { 'info' }
    [void](Show-Dialog $Msg $kind)
}

# ============================================================ modelos/presets
function Get-Models {
    $v2 = @{}
    Get-ChildItem -LiteralPath (Join-Path $ModelDir 'rife_v2') -Filter 'rife_v*.onnx' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $v2[$_.Name] = $true }

    $known = @{ 4161 = '4.16 lite  ·  rápido'; 426 = '4.26  ·  calidad' }
    $list = foreach ($f in Get-ChildItem -LiteralPath (Join-Path $ModelDir 'rife') -Filter 'rife_v*.onnx' -File -ErrorAction SilentlyContinue) {
        if ($f.Name -notmatch '^rife_v(\d+)\.(\d+)(_lite|_heavy)?\.onnx$') { continue }
        $variant = switch ($Matches[3]) { '_lite' { '1' } '_heavy' { '2' } default { '' } }
        $id = [int]('{0}{1}{2}' -f $Matches[1], $Matches[2], $variant)
        $label = if ($known.ContainsKey($id)) { $known[$id] } else { '{0}.{1}{2}' -f $Matches[1], $Matches[2], $Matches[3] }
        $short = '{0}.{1}{2}' -f $Matches[1], $Matches[2], ($Matches[3] -replace '_', ' ')
        [pscustomobject]@{ Id = $id; Label = $label; Short = $short; HasV2 = $v2.ContainsKey($f.Name) }
    }
    @($list | Sort-Object @{ Expression = { if ($_.Id -eq 4161) { 0 } else { 1 } } }, Id)
}

function Get-SelectedModel { if ($ui.CbModel.SelectedItem) { $ui.CbModel.SelectedItem.Tag } else { $null } }

function Get-Multi { if ($ui.CbFps.SelectedItem) { [string]$ui.CbFps.SelectedItem.Tag } else { '2' } }

function Get-Suffix { if ((Get-Multi) -eq '5/2') { '-2.5x' } else { $BaseSuffix } }

function Get-Dest([VsApp.VideoItem]$It) {
    if ($ui.RbSame.IsChecked) { [System.IO.Path]::GetDirectoryName($It.Path) } else { $OutputDir }
}

function Get-OutPath([VsApp.VideoItem]$It, [string]$Suffix = (Get-Suffix)) {
    Join-Path (Get-Dest $It) ($It.BaseName + $Suffix + '.mkv')
}

function Get-Snapshot {
    @{
        Model  = $ui.CbModel.SelectedIndex
        Cut    = [math]::Round($ui.SlCut.Value, 2)
        Cq     = [int]$ui.SlCq.Value
        Cas    = [math]::Round($ui.SlCas.Value, 2)
        Deband = [bool]$ui.ChkDeband.IsChecked
    }
}

function Import-Preset([string]$Name) {
    $v = Read-BatVars (Join-Path $PresetDir "$Name.bat")
    if ($v.RIFE_MODEL) {
        for ($i = 0; $i -lt $ui.CbModel.Items.Count; $i++) {
            if ($ui.CbModel.Items[$i].Tag.Id -eq [int]$v.RIFE_MODEL) { $ui.CbModel.SelectedIndex = $i }
        }
    }
    if ($null -ne (Get-Num "$($v.SCENE_THRESHOLD)")) { $ui.SlCut.Value = Get-Num $v.SCENE_THRESHOLD }
    if ($null -ne (Get-Num "$($v.CQ)"))              { $ui.SlCq.Value  = Get-Num $v.CQ }
    if ($null -ne (Get-Num "$($v.CAS_SHARPNESS)"))   { $ui.SlCas.Value = Get-Num $v.CAS_SHARPNESS }
    $ui.ChkDeband.IsChecked = ($v.DEBAND -eq '1')
    $S.BasePreset = $Name
    $S.PresetValues = Get-Snapshot
}

# ================================================================ lista
function Update-Notes {
    $suffix = Get-Suffix
    foreach ($it in $Items) {
        $parts = @()
        if ($it.Codec -eq 'av1') { $parts += 'AV1' }
        if (Test-Path -LiteralPath (Get-OutPath $it $suffix)) { $parts += 'ya existe' }
        $it.Note = $parts -join ' · '
    }
}

function Update-VideoList {
    $keep = @{}
    foreach ($it in $Items) { if ($it.Selected) { $keep[$it.Path] = $true } }
    $Items.Clear()
    $S.ProbeItem = $null

    $ui.TxInput.Text = "Videos en  $InputDir"
    if (Test-Path -LiteralPath $InputDir) {
        # Se excluyen las salidas (-2x, -2.5x) por si el destino es la misma carpeta.
        $files = Get-ChildItem -LiteralPath $InputDir -File |
                 Where-Object { $Exts -contains $_.Extension.ToLowerInvariant() -and $_.BaseName -notmatch '-\d+(\.\d+)?x$' } |
                 Sort-Object Name
        foreach ($f in $files) {
            $it = New-Object VsApp.VideoItem
            $it.Path = $f.FullName
            $it.Name = $f.Name
            $it.BaseName = $f.BaseName
            $it.SizeText = Format-Size $f.Length
            $it.Selected = $keep.ContainsKey($f.FullName)
            $Items.Add($it)
        }
    }
    if ($Items.Count -eq 0) {
        $ui.TxEmpty.Text = "No hay videos en`n$InputDir"
        $ui.TxEmpty.Visibility = 'Visible'
    } else {
        $ui.TxEmpty.Visibility = 'Collapsed'
    }
    Update-Notes
}

# Un ffprobe a la vez, sin bloquear la ventana: se lanza en un tick y se lee en
# el siguiente.
function Step-Probe {
    if ($S.ProbeProc) {
        if (-not $S.ProbeProc.HasExited) { return }
        $out = $S.ProbeProc.StandardOutput.ReadToEnd()
        $S.ProbeProc.Dispose()
        $S.ProbeProc = $null
        $it = $S.ProbeItem
        $S.ProbeItem = $null
        if ($it) {
            foreach ($line in $out -split "`r?`n") {
                if ($line -match '^codec_name=(.+)$')    { $it.Codec = $Matches[1].Trim() }
                if ($line -match '^r_frame_rate=(.+)$')  { $r = Get-Rate $Matches[1]; if ($r) { $it.Fps = $r } }
                if ($line -match '^duration=(.+)$')      { $d = Get-Num $Matches[1]; if ($d) { $it.Duration = $d } }
            }
            $it.DurationText = if ($it.Duration -gt 0) { Format-Time $it.Duration } else { '?' }
            $it.Probed = $true
            Update-Notes
        }
        return
    }
    $next = $null
    foreach ($it in $Items) { if (-not $it.Probed) { $next = $it; break } }
    if (-not $next) { return }
    $S.ProbeItem = $next
    $S.ProbeProc = Start-Hidden $Cfg.FFPROBE ('-v error -select_streams v:0 -show_entries stream=codec_name,r_frame_rate:format=duration -of default=nw=1 "{0}"' -f $next.Path) -Capture
}

# ================================================================ GPU
function Step-Gpu {
    if ($S.GpuProc) {
        if (-not $S.GpuProc.HasExited) { return }
        $line = $S.GpuProc.StandardOutput.ReadToEnd().Trim()
        $S.GpuProc.Dispose()
        $S.GpuProc = $null
        $f = @($line -split '\s*,\s*')
        if ($f.Count -ge 5 -and $null -ne (Get-Num $f[0])) {
            $S.Gpu = @{ Free = Get-Num $f[0]; Total = Get-Num $f[1]; Util = Get-Num $f[2]; Temp = Get-Num $f[3]; Power = Get-Num $f[4] }
        } else { $S.Gpu = $null }
        Show-Gpu
        return
    }
    if ($S.GpuWait -gt 0) { $S.GpuWait--; return }
    $S.GpuWait = 5
    try {
        $S.GpuProc = Start-Hidden 'nvidia-smi.exe' '--query-gpu=memory.free,memory.total,utilization.gpu,temperature.gpu,power.draw --format=csv,noheader,nounits' -Capture
    } catch {
        $S.Gpu = $null
        $S.GpuWait = 40
        Show-Gpu
    }
}

function Test-GpuBusy { $S.Gpu -and ($S.Gpu.Free -lt 2500 -or $S.Gpu.Util -gt 30) }

function Show-Gpu {
    $g = $S.Gpu
    if (-not $g) {
        $ui.GpuDot.Fill = $Brush.Gray
        $ui.TxGpu.Text = 'GPU: sin datos (nvidia-smi no respondió)'
        return
    }
    $mem = '{0:N1} GB libres' -f ($g.Free / 1024)
    $pow = if ($null -ne $g.Power) { ' · {0:N0} W' -f $g.Power } else { '' }
    if ($S.Running) {
        $ui.GpuDot.Fill = $Brush.Blue
        $ui.TxGpu.Text = 'GPU: {0:N0} % uso · {1:N0} °C{2} · {3}' -f $g.Util, $g.Temp, $pow, $mem
    } elseif (Test-GpuBusy) {
        $ui.GpuDot.Fill = $Brush.Amber
        $ui.TxGpu.Text = 'GPU: {0} · {1:N0} % uso  -  ocupada: cerrá juegos y apps pesadas antes de empezar' -f $mem, $g.Util
    } else {
        $ui.GpuDot.Fill = $Brush.Green
        $ui.TxGpu.Text = 'GPU: {0} · {1:N0} % uso · {2:N0} °C  -  lista' -f $mem, $g.Util, $g.Temp
    }
}

# ================================================================ cola
function Set-Running([bool]$On) {
    $S.Running = $On
    # Ver en tiempo real tambien se apaga: durante una cola los dos pelearian por
    # la GPU, la reproduccion iria a saltos y el render mas lento.
    foreach ($c in 'CbPreset', 'CbModel', 'CbFps', 'SlCut', 'SlCq', 'SlCas', 'RbOut', 'RbSame', 'ChkDeband',
                   'BtnAll', 'BtnNone', 'BtnRefresh', 'CbLiveFps', 'BtnLive', 'BtnLiveOpen') {
        $ui[$c].IsEnabled = -not $On
    }
    foreach ($it in $Items) { $it.Editable = -not $On }
    $ui.BtnStart.IsEnabled = -not $On
    $ui.BtnCancel.IsEnabled = $On
    [VsApp.Native]::KeepAwake($On)
    Show-Gpu
}

function Write-JobBat {
    $m = Get-SelectedModel
    $impl = if ($m.HasV2) { 2 } else { 0 }
    # El .bat se escribe en ASCII y sin rutas adentro: la raiz llega por la
    # variable VSAPP_ROOT y el video por argumento, asi los nombres con
    # caracteres raros viajan en UTF-16 y nunca pasan por la pagina de codigos.
    # Los decimales van con punto sin importar el idioma de Windows.
    $lines = @(
        '@echo off'
        'chcp 65001 >nul'
        ('set "PRESET={0}"' -f $S.BasePreset)
        'call "%VSAPP_ROOT%\config.bat"'
        ('set "RIFE_MODEL={0}"' -f $m.Id)
        ('set "RIFE_IMPL={0}"' -f $impl)
        ('set "RIFE_MULTI={0}"' -f (Get-Multi))
        'set "SCENE_DETECT=1"'
        ('set "SCENE_THRESHOLD={0}"' -f $ui.SlCut.Value.ToString('0.00', $Inv))
        ('set "CQ={0}"' -f [int]$ui.SlCq.Value)
        ('set "CAS_SHARPNESS={0}"' -f $ui.SlCas.Value.ToString('0.00', $Inv))
        ('set "DEBAND={0}"' -f [int][bool]$ui.ChkDeband.IsChecked)
        ('set "OUT_SUFFIX={0}"' -f (Get-Suffix))
        'call "%VSAPP_ROOT%\scripts\process-one.bat" "%~1" "%~2"'
        'exit /b %errorlevel%'
    )
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($JobBat, (($lines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
}

function Start-Queue {
    $sel = @($Items | Where-Object Selected)
    if ($sel.Count -eq 0) { Show-Message 'Tildá al menos un video.'; return }

    $missing = @($Required | Where-Object { -not $_ -or -not (Test-Path -LiteralPath $_) })
    if ($missing.Count) { Show-Message ("Falta:`n" + ($missing -join "`n")) 'Error'; return }
    if (-not (Get-SelectedModel)) { Show-Message 'No hay ningún modelo RIFE instalado.' 'Error'; return }

    if (Test-LiveOpen) {
        $msg = "Hay un video abierto en tiempo real. La cola y la reproducción van a pelear por la GPU: " +
               "el video va a ir a saltos y el render más lento.`n`n¿Iniciar igual?"
        if (-not (Ask $msg)) { return }
    } elseif (Test-GpuBusy) {
        $msg = "La GPU parece ocupada: {0:N1} GB libres, {1:N0} % de uso.`n`n" -f ($S.Gpu.Free / 1024), $S.Gpu.Util +
               "Con un juego abierto el render puede ir 50 veces más lento, y si TensorRT se queda sin VRAM " +
               "mientras compila deja un engine roto de 0 bytes.`n`n¿Iniciar igual?"
        if (-not (Ask $msg)) { return }
    }

    $suffix = Get-Suffix
    $exist = @($sel | Where-Object { Test-Path -LiteralPath (Get-OutPath $_ $suffix) })
    if ($exist.Count) {
        if (-not (Ask ("{0} de los videos elegidos ya tienen salida y se van a reemplazar.`n`n¿Continuar?" -f $exist.Count))) { return }
    }

    Write-JobBat
    $S.Suffix = $suffix
    $S.MultiValue = if ((Get-Multi) -eq '5/2') { 2.5 } else { 2.0 }
    $S.Queue = $sel
    $S.Index = 0; $S.Ok = 0; $S.Fail = 0
    $S.Cancelling = $false
    $S.QueueStart = Get-Date
    foreach ($it in $Items) { $it.Status = if ($it.Selected) { 'en cola' } else { '' } }
    $ui.PbQueue.Value = 0
    Set-Running $true
    Start-NextJob
}

function Start-NextJob {
    if ($S.Index -ge $S.Queue.Count) { Complete-Queue; return }
    $it = $S.Queue[$S.Index]
    $dest = Get-Dest $it
    if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

    $log = Join-Path $WorkDir ('app-job-{0:D2}.log' -f $S.Index)
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

    # /s + comillas exteriores: cmd saca solo el primer y el ultimo " y respeta
    # los internos, que es lo que hace falta con rutas con espacios y corchetes.
    $argLine = '/d /s /c ""{0}" "{1}" "{2}" > "{3}" 2>&1"' -f $JobBat, $it.Path, $dest, $log
    $proc = Start-Hidden $env:ComSpec $argLine -Env @{ VSAPP_ROOT = $Root }

    $S.Job = @{
        Proc = $proc; Item = $it; Log = $log; Dest = $dest
        Out = Join-Path $dest ($it.BaseName + $S.Suffix + '.mkv')
        Pos = [long]0; Decoder = [Text.Encoding]::UTF8.GetDecoder(); Carry = ''
        Phase = 0; SrcFrames = 0; SrcFps = 0.0; OutFps = 0.0; Total = 0; Frame = 0
        Samples = New-Object System.Collections.Generic.List[object]; Fps = 0.0
        Err = $null; Start = Get-Date
    }
    $it.Status = '▶ procesando'
    $ui.LvVideos.ScrollIntoView($it)
}

# Lee lo nuevo del log sin bloquearlo (cmd lo sigue escribiendo) y lo parsea.
# process-one.bat marca las fases con [1/3] [2/3] [3/3] [OK] [FALLO] [X], y
# ffmpeg escribe el progreso como "frame= 1234" separado por retornos de carro.
function Read-JobLog($j) {
    if (-not (Test-Path -LiteralPath $j.Log)) { return }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($j.Log, 'Open', 'Read', 'ReadWrite, Delete')
        if ($fs.Length -le $j.Pos) { return }
        $fs.Position = $j.Pos
        $count = [int][math]::Min($fs.Length - $j.Pos, 4MB)
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
        $j.Pos += $read
    } catch { return }
    finally { if ($fs) { $fs.Dispose() } }

    $chars = New-Object char[] ($j.Decoder.GetCharCount($buf, 0, $read))
    [void]$j.Decoder.GetChars($buf, 0, $read, $chars, 0)
    $text = $j.Carry + (New-Object string (, $chars))

    if (-not $j.SrcFrames) {
        $m = [regex]::Match($text, '\|\s*\d+x\d+ @ (\d+)/(\d+)\s*\|[^\r\n]*?frames=(\d+)')
        if ($m.Success) {
            $j.SrcFps = [double]$m.Groups[1].Value / [double]$m.Groups[2].Value
            $j.SrcFrames = [int]$m.Groups[3].Value
        }
    }
    if (-not $j.OutFps) {
        $m = [regex]::Match($text, 'salida: \d+x\d+ @ (\d+)/(\d+)')
        if ($m.Success) { $j.OutFps = [double]$m.Groups[1].Value / [double]$m.Groups[2].Value }
    }
    if (-not $j.Total -and $j.SrcFrames -and $j.SrcFps -and $j.OutFps) {
        $j.Total = [int][math]::Round($j.SrcFrames * $j.OutFps / $j.SrcFps)
    }

    if ($j.Phase -lt 1 -and $text.Contains('[1/3]')) { $j.Phase = 1 }
    if ($j.Phase -lt 2 -and $text.Contains('[2/3]')) { $j.Phase = 2 }
    if ($j.Phase -lt 3 -and $text.Contains('[3/3]')) { $j.Phase = 3 }
    if ($text.Contains('[OK]')) { $j.Phase = 4 }
    $m = [regex]::Match($text, '\[X\] ([^\r\n]+)')
    if ($m.Success) { $j.Err = $m.Groups[1].Value.Trim() }

    if ($j.Phase -eq 1) {
        $ms = [regex]::Matches($text, 'frame=\s*(\d+)')
        if ($ms.Count) {
            $f = [int]$ms[$ms.Count - 1].Groups[1].Value
            if ($f -gt $j.Frame) {
                $j.Frame = $f
                $now = [DateTime]::UtcNow
                $j.Samples.Add(@($now, $f))
                # Velocidad sobre los ultimos 5 s: refleja lo que pasa ahora
                # (por ejemplo cuando la placa toca el tope de potencia), no un
                # promedio desde el arranque que incluye la carga del engine.
                while ($j.Samples.Count -gt 2 -and ($now - $j.Samples[0][0]).TotalSeconds -gt 5) { $j.Samples.RemoveAt(0) }
                $dt = ($now - $j.Samples[0][0]).TotalSeconds
                if ($dt -ge 1) { $j.Fps = ($f - $j.Samples[0][1]) / $dt }
            }
        }
    }
    $j.Carry = if ($text.Length -gt 400) { $text.Substring($text.Length - 400) } else { $text }
}

function Get-QueueRemainingFrames($j) {
    $rest = 0.0
    if ($j.Total -gt 0) { $rest += [math]::Max(0, $j.Total - $j.Frame) }
    for ($k = $S.Index + 1; $k -lt $S.Queue.Count; $k++) {
        $q = $S.Queue[$k]
        if ($q.Duration -gt 0 -and $q.Fps -gt 0) { $rest += $q.Duration * $q.Fps * $S.MultiValue }
        else { return $null }
    }
    $rest
}

function Show-Job($j) {
    $it = $j.Item
    $ui.TxCurName.Text = $it.Name
    $frac = 0.0

    if ($j.Phase -ge 2) {
        $frac = 1.0
        $ui.PbCur.IsIndeterminate = $false
        $ui.PbCur.Value = 100
        $ui.TxCurPct.Text = '100 %'
        $ui.TxSpeed.Text = if ($j.Phase -eq 2) { 'Copiando audio y subtítulos…' } else { 'Muxeando…' }
        $ui.TxEta.Text = ''
    } elseif ($j.Frame -le 0) {
        $ui.PbCur.IsIndeterminate = $true
        $ui.TxCurPct.Text = ''
        $wait = ((Get-Date) - $j.Start).TotalSeconds
        $ui.TxSpeed.Text = if ($wait -gt 12) { 'Compilando TensorRT (solo la primera vez con esta configuración)…' } else { 'Preparando…' }
        $ui.TxEta.Text = '{0} transcurrido' -f (Format-Time $wait)
    } else {
        $ui.PbCur.IsIndeterminate = $false
        if ($j.Total -gt 0) {
            $frac = [math]::Min(1.0, $j.Frame / $j.Total)
            $ui.PbCur.Value = $frac * 100
            $ui.TxCurPct.Text = '{0:N0} %' -f ($frac * 100)
        } else {
            $ui.TxCurPct.Text = '{0:N0} frames' -f $j.Frame
        }
        if ($j.Fps -gt 0 -and $j.OutFps -gt 0) {
            $ui.TxSpeed.Text = '{0:N1} fps  ·  ×{1:N2} tiempo real' -f $j.Fps, ($j.Fps / $j.OutFps)
            $ui.TxEta.Text = if ($j.Total -gt 0) { '~{0} restante' -f (Format-Time (($j.Total - $j.Frame) / $j.Fps)) } else { '' }
        } else {
            $ui.TxSpeed.Text = 'Midiendo velocidad…'
            $ui.TxEta.Text = ''
        }
    }

    $n = $S.Queue.Count
    $ui.PbQueue.Value = (($S.Index + $frac) / $n) * 100
    $queueText = '{0} de {1}' -f ($S.Index + 1), $n
    if ($j.Fps -gt 0 -and $j.Phase -lt 2) {
        $rest = Get-QueueRemainingFrames $j
        if ($null -ne $rest) { $queueText += ' · ~{0} en total' -f (Format-Time ($rest / $j.Fps)) }
    }
    $ui.TxQueue.Text = $queueText
}

function Remove-Partial($j) {
    $b = $j.Item.BaseName
    foreach ($f in @("$b$($S.Suffix).video.mkv", "$b.audio.mka", "$b.probe.txt")) {
        Remove-Item -LiteralPath (Join-Path $WorkDir $f) -Force -ErrorAction SilentlyContinue
    }
    # Si se corto durante el mux, la salida esta a medias.
    if ($j.Phase -ge 3 -and $j.Phase -lt 4) { Remove-Item -LiteralPath $j.Out -Force -ErrorAction SilentlyContinue }
}

function Complete-Job($j) {
    $it = $j.Item
    $code = try { $j.Proc.ExitCode } catch { 1 }
    $elapsed = ((Get-Date) - $j.Start).TotalSeconds

    if ($code -eq 0 -and $j.Phase -ge 4) {
        $S.Ok++
        # Velocidad punta a punta, incluyendo carga del engine y mux: es la que
        # importa para calcular cuanto tarda una cola.
        $rt = if ($it.Duration -gt 0 -and $elapsed -gt 0) { ' · ×{0:N2}' -f ($it.Duration / $elapsed) } else { '' }
        $it.Status = '{0} {1}{2}' -f [char]0x2713, (Format-Time $elapsed), $rt
        Remove-Item -LiteralPath $j.Log -Force -ErrorAction SilentlyContinue
    } elseif ($S.Cancelling) {
        Remove-Partial $j
        Remove-Item -LiteralPath $j.Log -Force -ErrorAction SilentlyContinue
        $it.Status = '— cancelado'
    } else {
        $S.Fail++
        $why = if ($j.Err) { $j.Err } else { 'falló (log en cache\work)' }
        Remove-Partial $j
        $it.Status = '{0} {1}' -f [char]0x2717, $why
        Write-AppLog ("{0}: {1}  (log: {2})" -f $it.Name, $why, $j.Log)
    }
    try { $j.Proc.Dispose() } catch { }
    $S.Job = $null
    $S.Index++

    if ($S.Cancelling) {
        for ($k = $S.Index; $k -lt $S.Queue.Count; $k++) { $S.Queue[$k].Status = '' }
        Complete-Queue
    } else {
        Start-NextJob
    }
    Update-Notes
}

function Complete-Queue {
    $total = if ($S.QueueStart) { ((Get-Date) - $S.QueueStart).TotalSeconds } else { 0 }
    Set-Running $false
    $ui.PbCur.IsIndeterminate = $false
    $ui.TxEta.Text = ''
    $ui.TxCurPct.Text = ''
    if ($S.Cancelling) {
        $ui.TxCurName.Text = 'Cola cancelada'
        $ui.PbCur.Value = 0
    } else {
        $ui.TxCurName.Text = 'Cola terminada'
        $ui.PbCur.Value = 100
    }
    $done = $S.Ok + $S.Fail
    $ui.TxSpeed.Text = '{0} listos · {1} con error' -f $S.Ok, $S.Fail
    $ui.TxQueue.Text = '{0} de {1} · {2}' -f $done, $S.Queue.Count, (Format-Time $total)
    if ($S.Queue.Count) { $ui.PbQueue.Value = $done / $S.Queue.Count * 100 }
    $S.Cancelling = $false
    [System.Media.SystemSounds]::Asterisk.Play()
}

function Stop-Tree($j) {
    if ($j -and -not $j.Proc.HasExited) {
        # taskkill /T mata cmd.exe junto con vspipe y ffmpeg, que son hijos suyos.
        Start-Process -FilePath 'taskkill.exe' -ArgumentList '/PID', $j.Proc.Id, '/T', '/F' -WindowStyle Hidden -Wait
        [void]$j.Proc.WaitForExit(10000)
    }
}

function Stop-Queue([switch]$NoConfirm) {
    if (-not $S.Running) { return }
    if (-not $NoConfirm -and -not (Ask '¿Cancelar la cola? El video en curso se descarta.')) { return }
    $S.Cancelling = $true
    $j = $S.Job
    if ($j) {
        Stop-Tree $j
        Complete-Job $j
    } else {
        Complete-Queue
    }
}

# ============================================================= tiempo real
# Ver un video en mpv interpolado en vivo. Es independiente de la cola y no
# genera archivos. Toda la logica (variables, VapourSynth, mpv) vive en
# scripts\ver-en-vivo.bat, el mismo que usa Ver-en-vivo.bat al arrastrar un
# video: aca solo se lanza y se sigue su log.
$LiveBat = Join-Path $Root 'scripts\ver-en-vivo.bat'
$LiveLog = Join-Path $WorkDir 'en-vivo.log'

function Get-LiveFps { if ($ui.CbLiveFps.SelectedItem) { [string]$ui.CbLiveFps.SelectedItem.Tag } else { '48' } }

function Test-LiveOpen { $S.Live -and -not $S.Live.Proc.HasExited }

function Select-LiveFile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Elegí un video para ver en tiempo real'
    $dlg.Filter = 'Videos|' + (($Exts | ForEach-Object { "*$_" }) -join ';') + '|Todos los archivos|*.*'
    if (Test-Path -LiteralPath $InputDir) { $dlg.InitialDirectory = $InputDir }
    if ($dlg.ShowDialog($window)) { $dlg.FileName } else { $null }
}

# El marcado en la lista (clic sobre el nombre); si no hay, el primero tildado;
# si tampoco, se pregunta.
function Get-LiveTarget {
    $it = $ui.LvVideos.SelectedItem
    if (-not $it) { $it = $Items | Where-Object Selected | Select-Object -First 1 }
    if ($it) { $it.Path } else { Select-LiveFile }
}

function Read-LiveLog {
    try {
        $fs = [System.IO.File]::Open($LiveLog, 'Open', 'Read', 'ReadWrite, Delete')
        try { (New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { '' }
}

function Get-LiveError([string]$Log) {
    $lines = @($Log -split "`r?`n" | Where-Object { $_ -match '\[X\]|rror|Exception|FALLIDA|failed' } |
               Select-Object -First 4 | ForEach-Object { $_.Trim() })
    if ($lines.Count) { $lines -join "`n" } else { 'mpv no dio más detalle.' }
}

function Start-Live([string]$Path) {
    if (-not $Path) { return }
    if (Test-LiveOpen) { Show-Message 'Ya hay un video abierto en tiempo real. Cerrá esa ventana de mpv primero.'; return }
    $mpv = $Cfg.MPV
    if (-not $mpv -or -not (Test-Path -LiteralPath $mpv)) {
        Show-Message ("Falta mpv en`n{0}`n`nCorré tools\install-mpv.bat para descargarlo." -f $mpv) 'Error'
        return
    }
    if (Test-GpuBusy) {
        $msg = "La GPU parece ocupada: {0:N1} GB libres, {1:N0} % de uso.`n`n" -f ($S.Gpu.Free / 1024), $S.Gpu.Util +
               "Con otro programa usando la placa, la reproducción puede ir a saltos.`n`n¿Abrir igual?"
        if (-not (Ask $msg)) { return }
    }
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    $fps = Get-LiveFps
    # Igual que la cola: /s y comillas exteriores para rutas con espacios y
    # corchetes; el nombre viaja en UTF-16 y no pasa por la pagina de codigos.
    # VSAPP_NOPAUSE: el .bat corre sin ventana, una pausa lo dejaria colgado.
    $argLine = '/d /s /c ""{0}" {1} "{2}" > "{3}" 2>&1"' -f $LiveBat, $fps, $Path, $LiveLog
    $proc = Start-Hidden $env:ComSpec $argLine -Env @{ VSAPP_NOPAUSE = '1' }
    $S.Live = @{ Proc = $proc; Name = [System.IO.Path]::GetFileName($Path); Fps = $fps; Start = Get-Date; Warned = $false }
    Show-Live
}

function Show-Live {
    $l = $S.Live
    $log = Read-LiveLog
    $wait = ((Get-Date) - $l.Start).TotalSeconds
    $ui.TxCurName.Text = 'En tiempo real: ' + $l.Name
    $ui.TxCurPct.Text = ''
    # realtime.vpy escribe "[tiempo real] ..." cuando ya armo todo: de ahi en
    # mas mpv esta reproduciendo. Antes de eso, si tarda, es TensorRT
    # compilando el motor para una resolucion que no habia visto.
    if ($log.Contains('[tiempo real]')) {
        $ui.PbCur.IsIndeterminate = $false
        $ui.PbCur.Value = 0
        $ui.TxSpeed.Text = 'Reproduciendo a {0} fps en mpv  ·  Ctrl+I compara con el original' -f $l.Fps
        $ui.TxEta.Text = ''
    } else {
        $ui.PbCur.IsIndeterminate = $true
        $ui.TxSpeed.Text = if ($wait -gt 12) { 'Preparando TensorRT: la primera vez con esta resolución tarda unos 2 minutos…' } else { 'Abriendo mpv…' }
        $ui.TxEta.Text = '{0} transcurrido' -f (Format-Time $wait)
    }
    # Si el script falla, mpv sigue con el original sin avisar. El script de
    # mpv (rife-en-vivo.lua) deja esta marca en el log.
    if (-not $l.Warned -and $log.Contains('INTERPOLACION FALLIDA')) {
        $l.Warned = $true
        Write-AppLog ("tiempo real: fallo la interpolacion de {0} (log: {1})" -f $l.Name, $LiveLog)
        Show-Message ("La interpolación falló y mpv está mostrando el video original.`n`n" + (Get-LiveError $log) +
                      "`n`nDetalle en cache\work\en-vivo.log") 'Error'
    }
}

function Step-Live {
    $l = $S.Live
    if (-not $l) { return }
    if (-not $l.Proc.HasExited) {
        if (-not $S.Running) { Show-Live }
        return
    }
    $code = try { $l.Proc.ExitCode } catch { 0 }
    try { $l.Proc.Dispose() } catch { }
    $S.Live = $null
    if (-not $S.Running) {
        $ui.PbCur.IsIndeterminate = $false
        $ui.PbCur.Value = 0
        $ui.TxCurName.Text = 'Listo para empezar'
        $ui.TxCurPct.Text = ''; $ui.TxSpeed.Text = ''; $ui.TxEta.Text = ''
    }
    if ($code -ne 0) {
        Write-AppLog ("tiempo real: {0} termino con codigo {1} (log: {2})" -f $l.Name, $code, $LiveLog)
        Show-Message ("No se pudo reproducir en tiempo real.`n`n" + (Get-LiveError (Read-LiveLog)) +
                      "`n`nDetalle en cache\work\en-vivo.log") 'Error'
    }
}

# ================================================================ refresco
function Update-Idle {
    $sel = @($Items | Where-Object Selected)
    $dur = ($sel | Measure-Object Duration -Sum).Sum
    $ui.TxSelInfo.Text = if ($sel.Count) { '{0} de {1} · {2} de video' -f $sel.Count, $Items.Count, (Format-Time $dur) }
                         else { '{0} videos' -f $Items.Count }

    if ($S.PresetValues) {
        $now = Get-Snapshot
        $changed = $false
        foreach ($k in $now.Keys) { if ($now[$k] -ne $S.PresetValues[$k]) { $changed = $true } }
        $ui.TxPresetState.Text = if ($changed) { '· personalizado' } else { '' }
    }

    $m = Get-SelectedModel
    if ($m) {
        $impl = if ($m.HasV2) { 'implementación v2' } else { 'implementación v1' }
        $dest = if ($ui.RbSame.IsChecked) { 'junto al original' } else { $OutputDir }
        $ui.TxFooter.Text = 'RIFE {0} · {1} · salida: {2}' -f $m.Short, $impl, $dest
    }
}

function Invoke-Tick {
    try {
        if ($S.Job) {
            $j = $S.Job
            Read-JobLog $j
            $done = $j.Proc.HasExited
            if ($done) { Read-JobLog $j }
            Show-Job $j
            if ($done) { Complete-Job $j }
        }
        Step-Live
        Step-Probe
        Step-Gpu
        Update-Idle
    } catch {
        Write-AppLog ($_ | Out-String)
        if (-not $S.TickError) {
            $S.TickError = $true
            Show-Message ("Error al actualizar la ventana:`n`n" + $_.Exception.Message + "`n`nDetalle en cache\work\app-errores.log") 'Error'
        }
    }
}

# ================================================================ armado
$ui.RbOut.Content = (Split-Path $OutputDir -Leaf) + ''
$ui.RbOut.ToolTip = $OutputDir

foreach ($p in @(Get-ChildItem -LiteralPath $PresetDir -Filter '*.bat' -File | Where-Object { $_.BaseName -notlike '_*' } |
                 Sort-Object @{ Expression = { switch ($_.BaseName) { 'balanced' { 0 } 'speed' { 1 } 'quality' { 2 } default { 3 } } } })) {
    $ci = New-Object System.Windows.Controls.ComboBoxItem
    $ci.Content = switch ($p.BaseName) {
        'balanced' { 'balanced  ·  recomendado' }
        'speed'    { 'speed  ·  más rápido' }
        'quality'  { 'quality  ·  más lento' }
        default    { $p.BaseName }
    }
    $ci.Tag = $p.BaseName
    [void]$ui.CbPreset.Items.Add($ci)
}

foreach ($m in Get-Models) {
    $ci = New-Object System.Windows.Controls.ComboBoxItem
    $ci.Content = $m.Label
    $ci.Tag = $m
    [void]$ui.CbModel.Items.Add($ci)
}

foreach ($f in @(@('×2  ·  24 → 48 fps', '2'), @('×2.5  ·  24 → 60 fps', '5/2'))) {
    $ci = New-Object System.Windows.Controls.ComboBoxItem
    $ci.Content = $f[0]
    $ci.Tag = $f[1]
    [void]$ui.CbFps.Items.Add($ci)
}
$ui.CbFps.SelectedIndex = if ($Cfg.RIFE_MULTI -eq '5/2') { 1 } else { 0 }

foreach ($f in @(@('48 fps  ·  ×2', '48'), @('60 fps  ·  ×2.5', '60'))) {
    $ci = New-Object System.Windows.Controls.ComboBoxItem
    $ci.Content = $f[0]
    $ci.Tag = $f[1]
    [void]$ui.CbLiveFps.Items.Add($ci)
}
if ($ui.CbModel.Items.Count) { $ui.CbModel.SelectedIndex = 0 }

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.add_Tick({ Invoke-Tick })

$ui.CbPreset.add_SelectionChanged({ Invoke-Safe { if ($ui.CbPreset.SelectedItem) { Import-Preset $ui.CbPreset.SelectedItem.Tag } } })
$ui.CbFps.add_SelectionChanged({ Invoke-Safe { Update-Notes } })
$ui.RbOut.add_Checked({ Invoke-Safe { Update-Notes } })
$ui.RbSame.add_Checked({ Invoke-Safe { Update-Notes } })
$ui.BtnAll.add_Click({ foreach ($it in $Items) { $it.Selected = $true } })
$ui.BtnNone.add_Click({ foreach ($it in $Items) { $it.Selected = $false } })
$ui.BtnRefresh.add_Click({ Invoke-Safe { Update-VideoList } })
$ui.BtnStart.add_Click({ Invoke-Safe { Start-Queue } })
$ui.BtnCancel.add_Click({ Invoke-Safe { Stop-Queue } })
$ui.BtnTheme.add_Click({
    Invoke-Safe {
        Set-Theme $(if ($S.Theme -eq 'dark') { 'light' } else { 'dark' })
        Save-Settings
    }
})

$window.add_Closing({
    param($sender, $e)
    if ($S.Running) {
        if (Ask 'Hay una cola en curso. Cerrar la ventana la cancela y descarta el video actual. ¿Cerrar igual?') {
            Stop-Queue -NoConfirm
        } else {
            $e.Cancel = $true
        }
    }
})
$window.add_Closed({
    $timer.Stop()
    [VsApp.Native]::KeepAwake($false)
    # mpv sigue abierto si estaba reproduciendo: es otro proceso y no depende de la app.
    $live = if ($S.Live) { $S.Live.Proc } else { $null }
    foreach ($p in @($S.ProbeProc, $S.GpuProc, $live)) { if ($p) { try { $p.Dispose() } catch { } } }
})

$defaultPreset = if ($Cfg.PRESET) { $Cfg.PRESET } else { 'balanced' }
for ($i = 0; $i -lt $ui.CbPreset.Items.Count; $i++) {
    if ($ui.CbPreset.Items[$i].Tag -eq $defaultPreset) { $ui.CbPreset.SelectedIndex = $i }
}
if ($ui.CbPreset.SelectedIndex -lt 0 -and $ui.CbPreset.Items.Count) { $ui.CbPreset.SelectedIndex = 0 }

$saved = Read-Settings
Set-Theme $(if ($saved -and $saved.Theme) { [string]$saved.Theme } else { Get-SystemTheme })

# La eleccion guardada manda; si no hay, la de config.bat (RT_FPS).
$liveFps = if ($saved -and $saved.LiveFps) { [string]$saved.LiveFps } elseif ($Cfg.RT_FPS) { [string]$Cfg.RT_FPS } else { '48' }
$ui.CbLiveFps.SelectedIndex = if ($liveFps -eq '60') { 1 } else { 0 }
# Recien ahora, con el tema ya cargado: si se registrara antes, la seleccion
# inicial guardaria el tema por defecto encima del elegido.
$ui.CbLiveFps.add_SelectionChanged({ Invoke-Safe { Save-Settings } })
$ui.BtnLive.add_Click({ Invoke-Safe { Start-Live (Get-LiveTarget) } })
$ui.BtnLiveOpen.add_Click({ Invoke-Safe { Start-Live (Select-LiveFile) } })

Update-VideoList
Update-Idle
$timer.Start()

if (-not $NoShow) { [void]$window.ShowDialog() }
