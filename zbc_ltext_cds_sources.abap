*&---------------------------------------------------------------------*
*& ZBC_LTEXT — CDS entities of the STXL long text decoder
*& All table functions are implemented by methods of ZCLBC_LTEXT_DECODE
*& (see zclbc_ltext_decode.clas.abap.txt).
*& Tested on S/4HANA 2021 (SAP_BASIS 756), HANA 2.0.
*&---------------------------------------------------------------------*

* ---------------------------------------------------------------------
* DDLS ZF_BC_LTEXT_LINES — generic access, individual lines
* ---------------------------------------------------------------------
@EndUserText.label: 'SAPscript long text lines from STXL'
@AccessControl.authorizationCheck: #NOT_ALLOWED
define table function ZF_BC_LTEXT_LINES
with parameters
  @Environment.systemField: #CLIENT
  p_clnt   : abap.clnt,
  p_object : tdobject,
  p_id     : tdid,
  p_name   : tdobname,
  p_langu  : abap.char(1)
returns
{
  clnt     : abap.clnt;
  tdobject : tdobject;
  tdname   : tdobname;
  tdid     : tdid;
  tdspras  : spras;
  line_no  : abap.int4;
  tdformat : tdformat;
  tdline   : tdline;
}
implemented by method
  zclbc_ltext_decode=>get_lines;

* ---------------------------------------------------------------------
* DDLS ZF_BC_LTEXT_TEXT — lines aggregated into one field per text
* ---------------------------------------------------------------------
@EndUserText.label: 'SAPscript long text as one string'
@AccessControl.authorizationCheck: #NOT_ALLOWED
define table function ZF_BC_LTEXT_TEXT
with parameters
  @Environment.systemField: #CLIENT
  p_clnt   : abap.clnt,
  p_object : tdobject,
  p_id     : tdid,
  p_name   : tdobname,
  p_langu  : abap.char(1)
returns
{
  clnt      : abap.clnt;
  tdobject  : tdobject;
  tdname    : tdobname;
  tdid      : tdid;
  tdspras   : spras;
  line_cnt  : abap.int4;
  text_len  : abap.int4;
  tdtext    : abap.string;
  tdtext_c  : abap.char(1333);
}
implemented by method
  zclbc_ltext_decode=>get_texts;

* ---------------------------------------------------------------------
* DDLS ZF_FI_DOC_LTEXT — FI scenario: driver over STXH + APPLY_FILTER
* ---------------------------------------------------------------------
@EndUserText.label: 'FI document long texts, decoded on demand'
@AccessControl.authorizationCheck: #NOT_ALLOWED
@ClientHandling.type: #CLIENT_DEPENDENT
define table function ZF_FI_DOC_LTEXT
with parameters
  @Environment.systemField: #CLIENT
  p_clnt   : abap.clnt,
  p_filter : abap.sstring( 1333 )
returns
{
  clnt      : abap.clnt;
  bukrs     : bukrs;
  belnr     : belnr_d;
  gjahr     : gjahr;
  buzei     : buzei;
  tdobject  : tdobject;
  tdname    : tdobname;
  tdid      : tdid;
  tdspras   : spras;
  line_cnt  : abap.int4;
  text_len  : abap.int4;
  tdtext    : abap.char(1333);
}
implemented by method
  zclbc_ltext_decode=>get_fi_doc_texts;

* ---------------------------------------------------------------------
* DDLS ZI_BC_LONGTEXT_SEL — view entity joining STXH with decoded texts
* (consumed by the READ_TEXT-replacement FM for mass reads with masks)
* ---------------------------------------------------------------------
@EndUserText.label: 'SAPscript long texts, filtered'
@AccessControl.authorizationCheck: #NOT_ALLOWED
@Metadata.ignorePropagatedAnnotations: true
define view entity ZI_BC_LONGTEXT_SEL
  with parameters
    p_object : tdobject,
    p_id     : tdid,
    p_name   : tdobname,
    p_langu  : abap.char(1)
  as select from stxh as Header
    inner join ZF_BC_LTEXT_TEXT( p_clnt:   $session.client,
                                 p_object: $parameters.p_object,
                                 p_id:     $parameters.p_id,
                                 p_name:   $parameters.p_name,
                                 p_langu:  $parameters.p_langu ) as Text
      on  Text.tdobject = Header.tdobject
      and Text.tdname   = Header.tdname
      and Text.tdid     = Header.tdid
      and Text.tdspras  = Header.tdspras
{
      @EndUserText.label: 'Text object'
  key Header.tdobject,
      @EndUserText.label: 'Text name'
  key Header.tdname,
      @EndUserText.label: 'Text ID'
  key Header.tdid,
      @EndUserText.label: 'Language'
  key Header.tdspras,
      @EndUserText.label: 'Title'
      Header.tdtitle,
      @EndUserText.label: 'Lines in header'
      Header.tdtxtlines,
      @EndUserText.label: 'Created by'
      Header.tdfuser,
      @EndUserText.label: 'Created on'
      Header.tdfdate,
      @EndUserText.label: 'Changed by'
      Header.tdluser,
      @EndUserText.label: 'Changed on'
      Header.tdldate,
      @EndUserText.label: 'Decoded lines'
      Text.line_cnt,
      @EndUserText.label: 'Text length'
      Text.text_len,
      @EndUserText.label: 'Long text'
      Text.tdtext
}
