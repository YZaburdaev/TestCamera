//
// <!-- Copyright (C) Gurock Software GmbH. All rights reserved. -->
//
// <summary>
//   Contains defines needed to be compatible with multiple versions of
//   Borland/CodeGear Delphi.
// </summary>

{$IFDEF CONDITIONALEXPRESSIONS}
  {$IF CompilerVersion >= 15}
    {$DEFINE DELPHI7_OR_HIGHER}
  {$IFEND}
  {$IF CompilerVersion >= 17}
    {$DEFINE DELPHI2005_OR_HIGHER}
  {$IFEND}
  {$IF CompilerVersion >= 18}
    {$DEFINE DELPHI2006_OR_HIGHER}
  {$IFEND}
  {$IF CompilerVersion >= 20}
    {$DEFINE DELPHI2009_OR_HIGHER}
  {$IFEND}
  {$IF CompilerVersion >= 21}
    {$DEFINE DELPHI2010_OR_HIGHER}
  {$IFEND}
  {$IF CompilerVersion >= 22} // XE
    {$DEFINE DELPHI2011_OR_HIGHER}
  {$IFEND}
  {$IF CompilerVersion >= 23} // XE2
    {$DEFINE DELPHI2012_OR_HIGHER}
  {$IFEND}
  {$IF CompilerVersion >= 24} // XE3
    {$DEFINE DELPHI2013_OR_HIGHER}
  {$IFEND}
  {$IF CompilerVersion >= 25} // XE4
    {$DEFINE DELPHI2014_OR_HIGHER}
  {$IFEND}
  {$IF CompilerVersion >= 26} // XE5
    {$DEFINE DELPHIXE5_OR_HIGHER}
  {$IFEND}
  {$IF CompilerVersion >= 27} // XE5
    {$DEFINE DELPHIXE6_OR_HIGHER}
  {$IFEND}
{$ENDIF}

{$DEFINE SI_DISABLE_DB}         { Disables database methods }
{$DEFINE SI_DISABLE_RTTI}       { Disables RTTI usage (LogObject) }
{$DEFINE SI_DISABLE_GRAPHIC}    { Disables graphic methods }
{$DEFINE SI_DISABLE_ENCRYPT}    { Disables log file encryption  }

{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}
