{
  GotBox -- direct libayatana-appindicator tray (Linux).

  LCL's gtk2 tray publishes a StatusNotifier item, but names its icon after a
  per-run memory address in a /tmp scratch dir -- a name that churns and that
  StatusNotifier panels (e.g. xfce's ayatana indicator plugin) won't resolve, so
  they show a generic fallback (a gear). Working apps like Dropbox instead
  advertise a STABLE icon name (dropboxstatus-idle, ...) from a persistent theme
  directory. This unit does the same: it drives libayatana-appindicator directly,
  advertising fixed names (gotbox-idle, gotbox-synced, ...) from a directory we
  control, so the indicator shows the real GotBox icon.

  The library is loaded at runtime (dlopen) so there is no build/link dependency
  and the app still runs where it is absent (the caller falls back to LCL's
  TTrayIcon). The gtk/gobject symbols used for the popup menu are always present
  (the app is built with the LCL gtk2 widgetset).

  Copyright (C) 2026 Qianqian Fang. GPLv3-or-later (see gboxmain.pas header).
}
unit gboxappind;

{$mode objfpc}{$H+}

interface

{$IFDEF LINUX}
type
  { Called (on the GUI thread) when a menu item is clicked, with the id passed
    to AppIndAddItem. }
  TIndicatorAction = procedure(AId: PtrInt) of object;

{ True if libayatana-appindicator (or the older libappindicator) is loadable. }
function AppIndAvailable: Boolean;

{ Create the indicator with an id, an initial icon name, and a directory holding
  the named icon PNGs; AOnAction dispatches menu clicks. Builds an empty menu. }
procedure AppIndBegin(const AId, AIconName, AThemePath: string;
  AOnAction: TIndicatorAction);

{ Append a menu item. AActionId >= 0 dispatches through AOnAction on click; < 0
  makes the item disabled (e.g. a status line). Returns the item handle so its
  label can be updated later via AppIndSetItemLabel. }
function AppIndAddItem(const ACaption: string; AActionId: PtrInt): Pointer;
procedure AppIndAddSeparator;

{ Attach the built menu and make the indicator visible. }
procedure AppIndShow;

{ Switch the displayed icon (a name present in the theme dir) and its a11y text. }
procedure AppIndSetIcon(const AIconName, ADesc: string);
procedure AppIndSetItemLabel(AItem: Pointer; const ACaption: string);
{$ENDIF}

implementation

{$IFDEF LINUX}
uses
  SysUtils, dynlibs;

const
  APP_INDICATOR_CATEGORY_APPLICATION_STATUS = 1;
  APP_INDICATOR_STATUS_ACTIVE = 1;

// ---- gtk/gobject (always linked by the LCL gtk2 widgetset) -----------------
function gtk_menu_new: Pointer; cdecl; external 'libgtk-x11-2.0.so.0';
function gtk_menu_item_new_with_label(lbl: PChar): Pointer; cdecl;
  external 'libgtk-x11-2.0.so.0';
function gtk_separator_menu_item_new: Pointer; cdecl;
  external 'libgtk-x11-2.0.so.0';
procedure gtk_menu_shell_append(shell, child: Pointer); cdecl;
  external 'libgtk-x11-2.0.so.0';
procedure gtk_widget_show(w: Pointer); cdecl; external 'libgtk-x11-2.0.so.0';
procedure gtk_widget_show_all(w: Pointer); cdecl; external 'libgtk-x11-2.0.so.0';
procedure gtk_widget_set_sensitive(w: Pointer; s: LongBool); cdecl;
  external 'libgtk-x11-2.0.so.0';
procedure gtk_menu_item_set_label(item: Pointer; lbl: PChar); cdecl;
  external 'libgtk-x11-2.0.so.0';
function g_signal_connect_data(instance: Pointer; signal: PChar;
  handler, data, destroy_notify: Pointer; flags: LongInt): PtrUInt; cdecl;
  external 'libgobject-2.0.so.0';

// ---- libayatana-appindicator (loaded at runtime) ---------------------------
type
  Tai_new = function(id, icon_name: PChar; category: LongInt): Pointer; cdecl;
  Tai_set_status = procedure(self: Pointer; status: LongInt); cdecl;
  Tai_set_icon_full = procedure(self: Pointer; icon_name, icon_desc: PChar); cdecl;
  Tai_set_theme_path = procedure(self: Pointer; path: PChar); cdecl;
  Tai_set_menu = procedure(self: Pointer; menu: Pointer); cdecl;

var
  gLib: TLibHandle = NilHandle;
  ai_new: Tai_new = nil;
  ai_set_status: Tai_set_status = nil;
  ai_set_icon_full: Tai_set_icon_full = nil;
  ai_set_theme_path: Tai_set_theme_path = nil;
  ai_set_menu: Tai_set_menu = nil;
  gInd: Pointer = nil;
  gMenu: Pointer = nil;
  gAction: TIndicatorAction = nil;

function AppIndAvailable: Boolean;
begin
  if gLib = NilHandle then
    gLib := LoadLibrary('libayatana-appindicator3.so.1');
  if gLib = NilHandle then
    gLib := LoadLibrary('libappindicator3.so.1');   // older/alt name
  if gLib = NilHandle then
    Exit(False);
  ai_new := Tai_new(GetProcedureAddress(gLib, 'app_indicator_new'));
  ai_set_status := Tai_set_status(GetProcedureAddress(gLib, 'app_indicator_set_status'));
  ai_set_icon_full := Tai_set_icon_full(
    GetProcedureAddress(gLib, 'app_indicator_set_icon_full'));
  ai_set_theme_path := Tai_set_theme_path(
    GetProcedureAddress(gLib, 'app_indicator_set_icon_theme_path'));
  ai_set_menu := Tai_set_menu(GetProcedureAddress(gLib, 'app_indicator_set_menu'));
  Result := Assigned(ai_new) and Assigned(ai_set_status) and
    Assigned(ai_set_icon_full) and Assigned(ai_set_theme_path) and
    Assigned(ai_set_menu);
end;

{ gtk "activate" signal handler; the item's action id is passed as user data. }
procedure ItemActivateCB(widget: Pointer; data: Pointer); cdecl;
begin
  if Assigned(gAction) then
    gAction(PtrInt(data));
end;

procedure AppIndBegin(const AId, AIconName, AThemePath: string;
  AOnAction: TIndicatorAction);
begin
  gAction := AOnAction;
  gMenu := gtk_menu_new;
  // Create with the id as the initial icon (resolvable in the system theme), so
  // the first lookup doesn't fail before our theme path is registered. THEN add
  // the per-status dir and switch to the requested icon -- otherwise the panel
  // caches the failed initial lookup and keeps showing a fallback icon.
  gInd := ai_new(PChar(AId), PChar(AId),
    APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  if AThemePath <> '' then
    ai_set_theme_path(gInd, PChar(AThemePath));
  if (AIconName <> '') and (AIconName <> AId) then
    ai_set_icon_full(gInd, PChar(AIconName), PChar(AId));
end;

function AppIndAddItem(const ACaption: string; AActionId: PtrInt): Pointer;
begin
  Result := gtk_menu_item_new_with_label(PChar(ACaption));
  if AActionId >= 0 then
    g_signal_connect_data(Result, 'activate', @ItemActivateCB,
      Pointer(PtrInt(AActionId)), nil, 0)
  else
    gtk_widget_set_sensitive(Result, False);
  gtk_menu_shell_append(gMenu, Result);
  gtk_widget_show(Result);
end;

procedure AppIndAddSeparator;
var
  it: Pointer;
begin
  it := gtk_separator_menu_item_new;
  gtk_menu_shell_append(gMenu, it);
  gtk_widget_show(it);
end;

procedure AppIndShow;
begin
  gtk_widget_show_all(gMenu);
  ai_set_menu(gInd, gMenu);
  ai_set_status(gInd, APP_INDICATOR_STATUS_ACTIVE);
end;

procedure AppIndSetIcon(const AIconName, ADesc: string);
begin
  if Assigned(ai_set_icon_full) and (gInd <> nil) then
    ai_set_icon_full(gInd, PChar(AIconName), PChar(ADesc));
end;

procedure AppIndSetItemLabel(AItem: Pointer; const ACaption: string);
begin
  if AItem <> nil then
    gtk_menu_item_set_label(AItem, PChar(ACaption));
end;
{$ENDIF}

end.
