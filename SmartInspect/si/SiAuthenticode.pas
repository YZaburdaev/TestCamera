unit SiAuthenticode;

interface

function GetAuthenticodeSignatureInfo: string;

implementation

uses
  System.SysUtils,
  System.DateUtils,
  System.Math,
  WinApi.Windows,
  Winapi.WinCrypt,
  JclPeImage;


function FileTimeToDateTime(FileTime: TFileTime): TDateTime;
var
  ModifiedTime: TFileTime;
  SystemTime: TSystemTime;
begin
  Result := 0;
  if (FileTime.dwLowDateTime = 0) and (FileTime.dwHighDateTime = 0) then
    Exit;
  try
    FileTimeToLocalFileTime(FileTime, ModifiedTime);
    FileTimeToSystemTime(ModifiedTime, SystemTime);
    Result := SystemTimeToDateTime(SystemTime);
  except
    Result := Now;  // Something to return in case of error
  end;
end;

function GetCounterSignerInfo(SignerInfo: PCMsgSignerInfo; Encoding: Cardinal; var CounterSignerInfo: PCMsgSignerInfo; var CounterSignerData: PCryptAttrBlob): Boolean;
begin
  if SignerInfo.UnauthAttrs.cAttr = 0 then
    Exit(False);

  {$POINTERMATH ON}
  for var N := 0 to SignerInfo.UnauthAttrs.cAttr - 1 do
  begin
    var UAttr := SignerInfo.UnauthAttrs.rgAttr + N;
    var ObjId := UAttr.pszObjId;

    CounterSignerData := UAttr.rgValue;
    var BlobSize := CounterSignerData.cbData;
    var Blob := CounterSignerData.pbData;

    var CounterSignerInfoSize: DWord := 0;

    // RSA applied to the counter signature
    if ObjId = szOID_RSA_counterSign then
    begin
      if not CryptDecodeObject(Encoding, PKCS7_SIGNER_INFO, Blob, BlobSize, 0, nil, CounterSignerInfoSize)
      or (CounterSignerInfoSize = 0) then
        Exit(False);

      GetMem(CounterSignerInfo, CounterSignerInfoSize);

      if not CryptDecodeObject(Encoding, PKCS7_SIGNER_INFO, Blob, BlobSize, 0, nil, CounterSignerInfoSize) then
      begin
        FreeMem(CounterSignerInfo);
        Exit(False);
      end;

      Exit(True);
    end
    // Counter signature of a signature
    else if ObjId = szOID_RFC3161_counterSign then
    begin
      if UAttr.cValue = 0 then
        Continue;

      // decode blob
      var Msg := CryptMsgOpenToDecode(Encoding, 0, 0, 0, nil, nil);
      if not Assigned(Msg) then
        Continue;

      try
        CryptMsgUpdate(Msg, Blob, BlobSize, True);

        var ContentSize: DWord := 0;
        if not CryptMsgGetParam(Msg, CMSG_CONTENT_PARAM, 0, nil, ContentSize) or (ContentSize = 0) then
          Continue;

        var Content: Pointer;
        GetMem(Content, ContentSize);
        try
          CryptMsgGetParam(Msg, CMSG_CONTENT_PARAM, 0, Content, ContentSize);

          (*var TimestampInfoSize: DWord := 0;
          var TimestampInfo: PCryptTimestampInfo := nil;
          if CryptDecodeObjectEx(Encoding, TIMESTAMP_INFO, Content, ContentSize, 0, nil, nil, TimestampInfoSize) then
          begin
            GetMem(TimestampInfo, TimestampInfoSize);
            try
              if CryptDecodeObjectEx(Encoding, TIMESTAMP_INFO, Content, ContentSize, 0, nil, TimestampInfo, TimestampInfoSize) then
                var Timestamp := FileTimeToDateTime(TimestampInfo.ftTime);
            finally
              FreeMem(TimestampInfo);
            end;
          end;*)

          //Try to get signer info
          if not CryptMsgGetParam(Msg, CMSG_SIGNER_INFO_PARAM, 0, nil, CounterSignerInfoSize)
          or (CounterSignerInfoSize = 0) then
            Continue;

          GetMem(CounterSignerInfo, CounterSignerInfoSize);

          if CryptMsgGetParam(Msg, CMSG_SIGNER_INFO_PARAM, 0, CounterSignerInfo, CounterSignerInfoSize) then
            Exit(True);
        finally
          FreeMem(Content);
        end;

      finally
        CryptMsgClose(Msg);
      end;

    end;
  end;
  {$POINTERMATH OFF}
  Exit(False);
end;

function GetDateOfTimestamp(SignerInfo: PCMsgSignerInfo; Encoding: Cardinal; var Value: TDateTime): Boolean;
begin
  if SignerInfo.AuthAttrs.cAttr = 0 then
    Exit(False);

  {$POINTERMATH ON}
  for var N := 0 to SignerInfo.AuthAttrs.cAttr - 1 do
  begin
    var Attr := SignerInfo.AuthAttrs.rgAttr + N;
    var ObjId := Attr.pszObjId;
    // RSA applied to the signing date and time value
    if ObjId = szOID_RSA_signingTime then
    begin
      var BlobSize := Attr.rgValue.cbData;
      var Blob := Attr.rgValue.pbData;
      var Data: TFileTime;
      var DataSize: DWord := sizeof(Data);
      if not CryptDecodeObject(Encoding, ObjId, Blob, BlobSize, 0, @Data, DataSize) then
        Exit(False);
      Value := FileTimeToDateTime(Data);
      Exit(True);
    end;
  end;
  {$POINTERMATH OFF}
  Exit(False);
end;

function CertGetName(Context: PCertContext; Flags: Cardinal): string;
begin
  var Len := CertGetNameStringW(Context, CERT_NAME_SIMPLE_DISPLAY_TYPE, Flags, nil, nil, 0);
  if Len = 0 then
    Exit(string.Empty);

  SetLength(Result, Len - 1);
  if CertGetNameStringW(Context, CERT_NAME_SIMPLE_DISPLAY_TYPE, Flags, nil, PChar(Result), Len) = 0 then
    Exit(string.Empty);
end;

function GetAuthenticodeSignatureInfo: string;
begin
  var SB := TStringBuilder.Create;
  try
    var ModuleName := GetModuleName(GetModuleHandle(nil));

    var Encoding: Cardinal := 0; // X509_ASN_ENCODING, PKCS_7_ASN_ENCODING
    var ContentType: Cardinal := 0; // CERT_QUERY_CONTENT_XXXX
    var CertStore: HCERTSTORE := nil;
    var Msg: HCRYPTMSG := nil;

    if not CryptQueryObject(
      CERT_QUERY_OBJECT_FILE,
      PChar(ModuleName),
      CERT_QUERY_CONTENT_FLAG_ALL,
      CERT_QUERY_FORMAT_FLAG_ALL,
      0,
      @Encoding,
      @ContentType,
      nil,
      CertStore,
      Msg,
      nil
    ) then
      Exit;

    try
      if not Assigned(CertStore) then
        Exit;

      var DataSize: Cardinal;

      // количество подписантов (можно организовать цикл по ним)
      // CryptMsgGetParam(Msg, CMSG_SIGNER_COUNT_PARAM, 0, nil, DataSize);
      // var SignerCount: DWord;
      // CryptMsgGetParam(Msg, CMSG_SIGNER_COUNT_PARAM, 0, @SignerCount, DataSize);
      // SB.AppendFormat('Подписей: %d', [SignerCount]).AppendLine;

      // первый по списку подписант
      CryptMsgGetParam(Msg, CMSG_SIGNER_INFO_PARAM, 0, nil, DataSize);

      var SignerInfo: PCMsgSignerInfo;
      GetMem(SignerInfo, DataSize);
      try
        CryptMsgGetParam(Msg, CMSG_SIGNER_INFO_PARAM, 0, SignerInfo, DataSize);

        // сертификат подписанта
        var CertInfo: TCertInfo;
        CertInfo.Issuer := SignerInfo.Issuer;
        CertInfo.SerialNumber := SignerInfo.SerialNumber;
        var CertContext: PCertContext := CertFindCertificateInStore(CertStore, Encoding, 0, CERT_FIND_SUBJECT_CERT, @CertInfo, nil);
        if not Assigned(CertContext) then
          Exit;

        try
          var IssuerName := CertGetName(CertContext, CERT_NAME_ISSUER_FLAG);
          var SubjectName := CertGetName(CertContext, 0);
          var NotAfter: TDateTime := FileTimeToDateTime(CertContext.pCertInfo.NotAfter);
          // var NotBefore := FileTimeToDateTime(CertContext.pCertInfo.NotBefore);
          SB.AppendFormat('Приложение подписано сертификатом, выданным (кому) "%s" (кем) "%s", годным по "%s"', [SubjectName,  IssuerName, NotAfter.ToString]);
        finally
          CertFreeCertificateContext(CertContext);
        end;

        // встречная подпись поставщика метки времени
        var CounterSignerInfo: PCMsgSignerInfo;
        var CounterSignerData: PCryptAttrBlob;

        if GetCounterSignerInfo(SignerInfo, Encoding, CounterSignerInfo, CounterSignerData) then
        begin
          try

            var TimeStamp: TDateTime;
            if not GetDateOfTimestamp(CounterSignerInfo, Encoding, TimeStamp) then
              Exit;

            SB.AppendLine.AppendFormat('Отметка времени: "%s"', [TimeStamp.ToString]);

            // сертификат подписанта
            CertInfo.Issuer := CounterSignerInfo.Issuer;
            CertInfo.SerialNumber := CounterSignerInfo.SerialNumber;
            CertContext := CertFindCertificateInStore(CertStore, Encoding, 0, CERT_FIND_SUBJECT_CERT, @CertInfo, nil);

            var LCertStore: HCERTSTORE := nil;
            // сертификат подписанта отметки времени не лежит в общей куче
            if not Assigned(CertContext) then
            begin
              // возможно, сертификат подписанта отметки времени поставляется в составе информации о самом подписанте, в CounterSignerData
              LCertStore := CertOpenStore(CERT_STORE_PROV_PKCS7, Encoding, 0, 0, CounterSignerData);
              if not Assigned(LCertStore) then
                Exit;
              CertContext := CertFindCertificateInStore(LCertStore, Encoding, 0, CERT_FIND_SUBJECT_CERT, @CertInfo, nil);
            end;

            try
              if Assigned(CertContext) then
              begin
                var IssuerName := CertGetName(CertContext, CERT_NAME_ISSUER_FLAG);
                var SubjectName := CertGetName(CertContext, 0);
                var NotAfter: TDateTime := FileTimeToDateTime(CertContext.pCertInfo.NotAfter);

                SB.AppendFormat(' удостоверена сертификатом, выданным (кому) "%s" (кем) "%s", годным по "%s"', [SubjectName, IssuerName, NotAfter.ToString]);
                Exit;
              end;
            finally
              if Assigned(CertContext) then
                CertFreeCertificateContext(CertContext);
              if Assigned(LCertStore) then
                CertCloseStore(LCertStore, CERT_CLOSE_STORE_FORCE_FLAG);
            end;
          finally
            FreeMem(CounterSignerInfo);
          end;
        end
        else
        begin
          var TimeStamp := PeReadLinkerTimeStamp(ParamStr(0)); // UTC
          SB.AppendLine.AppendFormat('Отметка времени исполняемого файла: "%s"', [TTimeZone.Local.ToLocalTime(TimeStamp).ToString])
        end;
      finally
        FreeMem(SignerInfo);
      end;
    finally
      if Assigned(CertStore) then
        CertCloseStore(CertStore, 0);
      if Assigned(Msg) then
        CryptMsgClose(Msg);
    end;
  finally
    Result := SB.ToString;
    SB.Free;
  end;
end;

end.
