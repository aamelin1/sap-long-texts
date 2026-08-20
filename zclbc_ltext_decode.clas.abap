class zclbc_ltext_decode definition
  public
  final
  create public .

public section.

  interfaces if_amdp_marker_hdb .

  types:
    begin of ty_key,
      tdobject type tdobject,
      tdname   type tdobname,
      tdid     type tdid,
      tdspras  type spras,
    end of ty_key .
  types:
    tt_key type standard table of ty_key with default key .
  types:
    begin of ty_line,
      tdobject type tdobject,
      tdname   type tdobname,
      tdid     type tdid,
      tdspras  type spras,
      line_no  type i,
      tdformat type tdformat,
      tdline   type tdline,
    end of ty_line .
  types:
    tt_line type standard table of ty_line with default key .

  "! <p class="shorttext synchronized" lang="en">Decode SAPscript long texts for a given set of keys</p>
  "!
  "! @parameter iv_clnt | <p class="shorttext synchronized" lang="en">Client</p>
  "! @parameter it_keys | <p class="shorttext synchronized" lang="en">Text keys to decode (STXH key)</p>
  "! @parameter et_lines | <p class="shorttext synchronized" lang="en">Decoded text lines</p>
  class-methods decode_lines
    importing
      value(iv_clnt)  type mandt
      value(it_keys)  type tt_key
    exporting
      value(et_lines) type tt_line .

  class-methods get_lines for table function zf_bc_ltext_lines .
  class-methods get_texts for table function zf_bc_ltext_text .
  class-methods get_fi_doc_texts for table function zf_fi_doc_ltext .

protected section.
private section.
endclass.



class zclbc_ltext_decode implementation.


  method get_lines by database function for hdb language sqlscript options read-only
                   using stxl zclbc_ltext_decode=>decode_lines.

    declare decode_err condition for sql_error_code 10001;

    -- decoding the whole table is never the intent: demand a restriction
    if :p_object = '' and :p_id = '' and :p_name = '' then
      signal decode_err set message_text = 'ZBC_LTEXT: restrict at least one of TDOBJECT, TDID, TDNAME';
    end if;

    -- key set under the same LIKE semantics this TF always had
    lt_keys = select distinct tdobject, tdname, tdid, tdspras
                from stxl
               where mandt = :p_clnt
                 and relid = 'TX'
                 and tdobject like case when :p_object = '' then '%' else :p_object end
                 and tdid     like case when :p_id     = '' then '%' else :p_id     end
                 and tdname   like case when :p_name   = '' then '%' else :p_name   end
                 and ( :p_langu = '' or tdspras = :p_langu );

    -- one call for the whole key set: the decoder body lives only in decode_lines
    call "ZCLBC_LTEXT_DECODE=>DECODE_LINES"( iv_clnt  => :p_clnt,
                                             it_keys  => :lt_keys,
                                             et_lines => lt_lines );

    return select :p_clnt as clnt,
                  tdobject, tdname, tdid, tdspras, line_no, tdformat, tdline
             from :lt_lines
            order by tdobject, tdname, tdid, tdspras, line_no;

  endmethod.


  method get_texts by database function for hdb language sqlscript options read-only using zf_bc_ltext_lines.

    lt_lines = select tdobject, tdname, tdid, tdspras, line_no, tdline
                 from "ZF_BC_LTEXT_LINES"( p_clnt   => :p_clnt,
                                           p_object => :p_object,
                                           p_id     => :p_id,
                                           p_name   => :p_name,
                                           p_langu  => :p_langu );

    return select :p_clnt as clnt,
                  tdobject,
                  tdname,
                  tdid,
                  tdspras,
                  count(*) as line_cnt,
                  length( string_agg( tdline, char(10) order by line_no ) ) as text_len,
                  string_agg( tdline, char(10) order by line_no ) as tdtext,
                  left( string_agg( tdline, char(10) order by line_no ), 1333 ) as tdtext_c
             from :lt_lines
            group by tdobject, tdname, tdid, tdspras;

  endmethod.


  method get_fi_doc_texts by database function for hdb language sqlscript options read-only
                          using stxh zclbc_ltext_decode=>decode_lines.

    declare l_filter nvarchar( 4000 );

    -- driver: text headers of FI documents, business keys parsed out of tdname.
    -- BELEG    = document header text, tdname = bukrs + belnr + gjahr
    -- DOC_ITEM = line item text,       tdname = bukrs + belnr + gjahr + buzei
    lt_drv = select tdobject,
                    tdname,
                    tdid,
                    tdspras,
                    substring( tdname,  1,  4 ) as bukrs,
                    substring( tdname,  5, 10 ) as belnr,
                    substring( tdname, 15,  4 ) as gjahr,
                    case when length( rtrim( tdname ) ) > 18
                         then substring( tdname, 19, 3 )
                         else '' end            as buzei
               from stxh
              where mandt = :p_clnt
                and tdobject in ( 'BELEG', 'DOC_ITEM' );

    -- select-options of the caller arrive as one predicate string and cut the
    -- driver down before anything is decoded
    l_filter := case when :p_filter = '' then '1 = 1' else :p_filter end;

    lt_flt = apply_filter( :lt_drv, :l_filter );

    lt_keys = select tdobject, tdname, tdid, tdspras from :lt_flt;

    -- the whole key set goes into the decoder in one call: no per text
    -- invocation, no nested table functions, no clob on the way out
    call "ZCLBC_LTEXT_DECODE=>DECODE_LINES"( iv_clnt  => :p_clnt,
                                             it_keys  => :lt_keys,
                                             et_lines => lt_lines );

    return select :p_clnt as clnt,
                  substring( tdname,  1,  4 ) as bukrs,
                  substring( tdname,  5, 10 ) as belnr,
                  substring( tdname, 15,  4 ) as gjahr,
                  case when length( rtrim( tdname ) ) > 18
                       then substring( tdname, 19, 3 )
                       else '' end            as buzei,
                  tdobject,
                  tdname,
                  tdid,
                  tdspras,
                  cast( count(*) as integer )                                  as line_cnt,
                  cast( sum( length( tdline ) ) + count(*) - 1 as integer )    as text_len,
                  left( string_agg( tdline, char(10) order by line_no ), 1333 ) as tdtext
             from :lt_lines
            group by tdobject, tdname, tdid, tdspras;

  endmethod.


  method decode_lines by database procedure for hdb language sqlscript options read-only using stxl.
    declare l_client   nvarchar(3);
    declare l_n        integer;
    declare l_i        integer;
    declare l_j        integer;
    declare l_j2       integer;
    declare l_j3       integer;
    declare l_k        integer;
    declare l_k2       integer;
    declare l_c        integer;
    declare l_cc       integer;
    declare l_ix       integer;
    declare l_tmp      integer;
    declare l_tot      integer;
    declare l_code2    integer;
    declare l_hn       integer;
    declare l_hx       nvarchar(3800);
    declare l_h1       integer;
    declare l_h2       integer;
    declare l_in_n     integer;
    declare l_out_n    integer;
    declare l_p        integer;
    declare l_m        integer;
    declare l_ver      integer;
    declare l_cp       nvarchar(4);
    declare l_csize    integer;
    declare l_expect   integer;
    declare l_algo     integer;
    declare l_bpos     integer;
    declare l_bbuf     integer;
    declare l_bcnt     integer;
    declare l_bit      integer;
    declare l_code     integer;
    declare l_len      integer;
    declare l_sym      integer;
    declare l_blc      integer;
    declare l_rep      integer;
    declare l_fill     integer;
    declare l_lastlen  integer;
    declare l_cl_n     integer;
    declare l_last     integer;
    declare l_btype    integer;
    declare l_eob      integer;
    declare l_nlit     integer;
    declare l_ndist    integer;
    declare l_nbl      integer;
    declare l_lc       integer;
    declare l_dc2      integer;
    declare l_nb       integer;
    declare l_v1       integer;
    declare l_v2       integer;
    declare l_mlen     integer;
    declare l_dist     integer;
    declare l_wc       integer;
    declare l_src      integer;
    declare l_b        integer;
    declare l_nf       integer;
    declare l_rowlen   integer;
    declare l_rowsum   integer;
    declare l_rowstart integer;
    declare l_namelen  integer;
    declare l_lineno   integer;
    declare l_chcode   integer;
    declare l_chpos    integer;
    declare l_fmt      nvarchar(2);
    declare l_line     nvarchar(300);
    declare l_o_n      integer;
    declare l_grp_new  integer;
    declare la_in      integer array;
    declare la_out     integer array;
    declare la_pow2    integer array;
    declare la_cl      integer array;
    declare la_pos     integer array;
    declare la_rank    integer array;
    declare la_lenx    integer array;
    declare la_lens    integer array;
    declare la_dstx    integer array;
    declare la_dsts    integer array;
    declare la_win     integer array;
    declare la_t1_cnt  integer array;
    declare la_t1_first integer array;
    declare la_t1_offs integer array;
    declare la_t1_syms integer array;
    declare la_t2_cnt  integer array;
    declare la_t2_first integer array;
    declare la_t2_offs integer array;
    declare la_t2_syms integer array;
    declare la_t3_cnt  integer array;
    declare la_t3_first integer array;
    declare la_t3_offs integer array;
    declare la_t3_syms integer array;
    declare la_g_object nvarchar(10) array;
    declare la_g_name  nvarchar(70) array;
    declare la_g_id    nvarchar(4) array;
    declare la_g_spras nvarchar(1) array;
    declare la_g_h1    nvarchar(3800) array;
    declare la_g_h2    nvarchar(3800) array;
    declare la_g_h3    nvarchar(3800) array;
    declare la_g_h4    nvarchar(3800) array;
    declare la_g_h5    nvarchar(3800) array;
    declare la_o_object nvarchar(10) array;
    declare la_o_name  nvarchar(70) array;
    declare la_o_id    nvarchar(4) array;
    declare la_o_spras nvarchar(1) array;
    declare la_o_line  integer array;
    declare la_o_fmt   nvarchar(2) array;
    declare la_o_text  nvarchar(132) array;
    declare decode_err condition for sql_error_code 10001;

    l_client := :iv_clnt;

    lt_stxl = select s.tdobject, s.tdname, s.tdid, s.tdspras, s.srtf2,
                     bintohex( substring( substring( s.clustd, 1, s.clustr ), 1,    1900 ) ) as h1,
                     bintohex( substring( substring( s.clustd, 1, s.clustr ), 1901, 1900 ) ) as h2,
                     bintohex( substring( substring( s.clustd, 1, s.clustr ), 3801, 1900 ) ) as h3,
                     bintohex( substring( substring( s.clustd, 1, s.clustr ), 5701, 1900 ) ) as h4,
                     bintohex( substring( substring( s.clustd, 1, s.clustr ), 7601, 1900 ) ) as h5
                from ( select distinct tdobject, tdname, tdid, tdspras
                         from :it_keys ) as k
               inner join stxl as s
                  on s.mandt    = :l_client
                 and s.relid    = 'TX'
                 and s.tdobject = k.tdobject
                 and s.tdname   = k.tdname
                 and s.tdid     = k.tdid
                 and s.tdspras  = k.tdspras
               order by s.tdobject, s.tdname, s.tdid, s.tdspras, s.srtf2;

    l_n := record_count( :lt_stxl );

    if :l_n > 0 then

      la_g_object = array_agg( :lt_stxl.tdobject );
      la_g_name   = array_agg( :lt_stxl.tdname );
      la_g_id     = array_agg( :lt_stxl.tdid );
      la_g_spras  = array_agg( :lt_stxl.tdspras );
      la_g_h1     = array_agg( :lt_stxl.h1 );
      la_g_h2     = array_agg( :lt_stxl.h2 );
      la_g_h3     = array_agg( :lt_stxl.h3 );
      la_g_h4     = array_agg( :lt_stxl.h4 );
      la_g_h5     = array_agg( :lt_stxl.h5 );

      l_j := 1;
      l_c := 1;
      while :l_j <= 25 do
        la_pow2[:l_j] := :l_c;
        l_c := :l_c * 2;
        l_j := :l_j + 1;
      end while;

      la_rank[1] := 17; la_rank[2] := 18; la_rank[3] := 19; la_rank[4] := 1;
      la_rank[5] := 9;  la_rank[6] := 8;  la_rank[7] := 10; la_rank[8] := 7;
      la_rank[9] := 11; la_rank[10] := 6; la_rank[11] := 12; la_rank[12] := 5;
      la_rank[13] := 13; la_rank[14] := 4; la_rank[15] := 14; la_rank[16] := 3;
      la_rank[17] := 15; la_rank[18] := 2; la_rank[19] := 16;

      l_j := 1;
      while :l_j <= 8 do
        la_lenx[:l_j] := 0;
        l_j := :l_j + 1;
      end while;
      l_c := 1;
      while :l_c <= 5 do
        l_j := 1;
        while :l_j <= 4 do
          l_ix := 8 + ( :l_c - 1 ) * 4 + :l_j;
          la_lenx[:l_ix] := :l_c;
          l_j := :l_j + 1;
        end while;
        l_c := :l_c + 1;
      end while;
      la_lenx[29] := 0;
      l_c := 3;
      l_j := 1;
      while :l_j <= 28 do
        la_lens[:l_j] := :l_c;
        l_ix := :la_lenx[:l_j] + 1;
        l_c := :l_c + :la_pow2[:l_ix];
        l_j := :l_j + 1;
      end while;
      la_lens[29] := 258;

      l_j := 1;
      while :l_j <= 30 do
        if :l_j <= 4 then
          la_dstx[:l_j] := 0;
        else
          la_dstx[:l_j] := floor( ( :l_j - 3 ) / 2 );
        end if;
        l_j := :l_j + 1;
      end while;
      l_c := 1;
      l_j := 1;
      while :l_j <= 30 do
        la_dsts[:l_j] := :l_c;
        l_ix := :la_dstx[:l_j] + 1;
        l_c := :l_c + :la_pow2[:l_ix];
        l_j := :l_j + 1;
      end while;

      l_o_n  := 0;
      l_in_n := 0;
      l_i    := 1;


      while :l_i <= :l_n do

      l_hx := ifnull( :la_g_h1[:l_i], '' );
      l_hn := length( :l_hx );
      l_j := 1;
      while :l_j <= :l_hn do
        l_h1 := locate( '123456789ABCDEF', substring( :l_hx, :l_j, 1 ) );
        l_ix := :l_j + 1;
        l_h2 := locate( '123456789ABCDEF', substring( :l_hx, :l_ix, 1 ) );
        l_in_n := :l_in_n + 1;
        la_in[:l_in_n] := :l_h1 * 16 + :l_h2;
        l_j := :l_j + 2;
      end while;
      l_hx := ifnull( :la_g_h2[:l_i], '' );
      l_hn := length( :l_hx );
      l_j := 1;
      while :l_j <= :l_hn do
        l_h1 := locate( '123456789ABCDEF', substring( :l_hx, :l_j, 1 ) );
        l_ix := :l_j + 1;
        l_h2 := locate( '123456789ABCDEF', substring( :l_hx, :l_ix, 1 ) );
        l_in_n := :l_in_n + 1;
        la_in[:l_in_n] := :l_h1 * 16 + :l_h2;
        l_j := :l_j + 2;
      end while;
      l_hx := ifnull( :la_g_h3[:l_i], '' );
      l_hn := length( :l_hx );
      l_j := 1;
      while :l_j <= :l_hn do
        l_h1 := locate( '123456789ABCDEF', substring( :l_hx, :l_j, 1 ) );
        l_ix := :l_j + 1;
        l_h2 := locate( '123456789ABCDEF', substring( :l_hx, :l_ix, 1 ) );
        l_in_n := :l_in_n + 1;
        la_in[:l_in_n] := :l_h1 * 16 + :l_h2;
        l_j := :l_j + 2;
      end while;
      l_hx := ifnull( :la_g_h4[:l_i], '' );
      l_hn := length( :l_hx );
      l_j := 1;
      while :l_j <= :l_hn do
        l_h1 := locate( '123456789ABCDEF', substring( :l_hx, :l_j, 1 ) );
        l_ix := :l_j + 1;
        l_h2 := locate( '123456789ABCDEF', substring( :l_hx, :l_ix, 1 ) );
        l_in_n := :l_in_n + 1;
        la_in[:l_in_n] := :l_h1 * 16 + :l_h2;
        l_j := :l_j + 2;
      end while;
      l_hx := ifnull( :la_g_h5[:l_i], '' );
      l_hn := length( :l_hx );
      l_j := 1;
      while :l_j <= :l_hn do
        l_h1 := locate( '123456789ABCDEF', substring( :l_hx, :l_j, 1 ) );
        l_ix := :l_j + 1;
        l_h2 := locate( '123456789ABCDEF', substring( :l_hx, :l_ix, 1 ) );
        l_in_n := :l_in_n + 1;
        la_in[:l_in_n] := :l_h1 * 16 + :l_h2;
        l_j := :l_j + 2;
      end while;
        l_grp_new := 0;
        if :l_i = :l_n then
          l_grp_new := 1;
        else
          l_ix := :l_i + 1;
          if :la_g_object[:l_ix] != :la_g_object[:l_i]
             or :la_g_name[:l_ix] != :la_g_name[:l_i]
             or :la_g_id[:l_ix] != :la_g_id[:l_i]
             or :la_g_spras[:l_ix] != :la_g_spras[:l_i] then
            l_grp_new := 1;
          end if;
        end if;

        if :l_grp_new = 1 and :l_in_n > 16 then

          if :la_in[1] != 255 then
            signal decode_err set message_text = 'STXL: stream does not start with FF';
          end if;
          l_ver := :la_in[2];
          l_cp  := nchar( :la_in[9] ) || nchar( :la_in[10] ) || nchar( :la_in[11] ) || nchar( :la_in[12] );
          if substring( :l_cp, 1, 1 ) = '8' then
            signal decode_err set message_text = 'STXL: unsupported MBCS codepage ' || :l_cp;
          end if;
          l_csize := 1;
          if :l_cp = '4103' or :l_cp = '4102' then
            l_csize := 2;
          end if;

          l_out_n := 0;
          if :l_in_n >= 24 and :la_in[22] = 31 and :la_in[23] = 157 then

          l_algo := :la_in[21];
          if :l_algo != 18 then
            signal decode_err set message_text = 'STXL: unsupported algorithm, only LZH';
          end if;
          l_expect := :la_in[17] + :la_in[18] * 256 + :la_in[19] * 65536 + :la_in[20] * 16777216;
          l_bpos := 25;
          l_bbuf := 0;
          l_bcnt := 0;
          l_wc   := 0;

      l_v1 := 0;
      l_k := 0;
      while :l_k < 2 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_v1 := :l_v1 + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
          if :l_v1 > 0 then
            l_nb := :l_v1;

      l_v2 := 0;
      l_k := 0;
      while :l_k < :l_nb do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_v2 := :l_v2 + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
          end if;
          l_last := 0;
          while :l_last = 0 do

      l_last := 0;
      l_k := 0;
      while :l_k < 1 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_last := :l_last + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;

      l_btype := 0;
      l_k := 0;
      while :l_k < 2 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_btype := :l_btype + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
            if :l_btype = 1 then
              l_j := 1;
              while :l_j <= 288 do
                if :l_j <= 144 then
                  la_cl[:l_j] := 8;
                elseif :l_j <= 256 then
                  la_cl[:l_j] := 9;
                elseif :l_j <= 280 then
                  la_cl[:l_j] := 7;
                else
                  la_cl[:l_j] := 8;
                end if;
                l_j := :l_j + 1;
              end while;

      l_j := 1;
      while :l_j <= 15 do
        la_t2_cnt[:l_j] := 0;
        l_j := :l_j + 1;
      end while;
      l_j := 1;
      while :l_j <= 288 do
        l_c := :la_cl[:l_j];
        if :l_c > 0 then
          la_t2_cnt[:l_c] := :la_t2_cnt[:l_c] + 1;
        end if;
        l_j := :l_j + 1;
      end while;
      l_code2 := 0;
      l_tot   := 0;
      l_j := 1;
      while :l_j <= 15 do
        if :l_j > 1 then
          l_ix    := :l_j - 1;
          l_code2 := ( :l_code2 + :la_t2_cnt[:l_ix] ) * 2;
        end if;
        la_t2_first[:l_j] := :l_code2;
        la_t2_offs[:l_j]  := :l_tot;
        l_tot := :l_tot + :la_t2_cnt[:l_j];
        la_pos[:l_j] := :l_tot - :la_t2_cnt[:l_j];
        l_j := :l_j + 1;
      end while;
      l_j := 1;
      while :l_j <= 288 do
        l_c := :la_cl[:l_j];
        if :l_c > 0 then
          la_pos[:l_c] := :la_pos[:l_c] + 1;
          l_ix := :la_pos[:l_c];
          la_t2_syms[:l_ix] := :l_j - 1;
        end if;
        l_j := :l_j + 1;
      end while;
              l_j := 1;
              while :l_j <= 30 do
                la_cl[:l_j] := 5;
                l_j := :l_j + 1;
              end while;

      l_j := 1;
      while :l_j <= 15 do
        la_t3_cnt[:l_j] := 0;
        l_j := :l_j + 1;
      end while;
      l_j := 1;
      while :l_j <= 30 do
        l_c := :la_cl[:l_j];
        if :l_c > 0 then
          la_t3_cnt[:l_c] := :la_t3_cnt[:l_c] + 1;
        end if;
        l_j := :l_j + 1;
      end while;
      l_code2 := 0;
      l_tot   := 0;
      l_j := 1;
      while :l_j <= 15 do
        if :l_j > 1 then
          l_ix    := :l_j - 1;
          l_code2 := ( :l_code2 + :la_t3_cnt[:l_ix] ) * 2;
        end if;
        la_t3_first[:l_j] := :l_code2;
        la_t3_offs[:l_j]  := :l_tot;
        l_tot := :l_tot + :la_t3_cnt[:l_j];
        la_pos[:l_j] := :l_tot - :la_t3_cnt[:l_j];
        l_j := :l_j + 1;
      end while;
      l_j := 1;
      while :l_j <= 30 do
        l_c := :la_cl[:l_j];
        if :l_c > 0 then
          la_pos[:l_c] := :la_pos[:l_c] + 1;
          l_ix := :la_pos[:l_c];
          la_t3_syms[:l_ix] := :l_j - 1;
        end if;
        l_j := :l_j + 1;
      end while;
            elseif :l_btype = 2 then

      l_v1 := 0;
      l_k := 0;
      while :l_k < 5 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_v1 := :l_v1 + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
              l_nlit := 257 + :l_v1;

      l_v1 := 0;
      l_k := 0;
      while :l_k < 5 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_v1 := :l_v1 + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
              l_ndist := 1 + :l_v1;

      l_v1 := 0;
      l_k := 0;
      while :l_k < 4 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_v1 := :l_v1 + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
              l_nbl := 4 + :l_v1;
              l_j := 1;
              while :l_j <= 19 do
                la_cl[:l_j] := 0;
                l_j := :l_j + 1;
              end while;
              l_j3 := 1;
              while :l_j3 <= :l_nbl do

      l_v1 := 0;
      l_k := 0;
      while :l_k < 3 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_v1 := :l_v1 + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
                l_ix := :la_rank[:l_j3];
                la_cl[:l_ix] := :l_v1;
                l_j3 := :l_j3 + 1;
              end while;

      l_j := 1;
      while :l_j <= 15 do
        la_t1_cnt[:l_j] := 0;
        l_j := :l_j + 1;
      end while;
      l_j := 1;
      while :l_j <= 19 do
        l_c := :la_cl[:l_j];
        if :l_c > 0 then
          la_t1_cnt[:l_c] := :la_t1_cnt[:l_c] + 1;
        end if;
        l_j := :l_j + 1;
      end while;
      l_code2 := 0;
      l_tot   := 0;
      l_j := 1;
      while :l_j <= 15 do
        if :l_j > 1 then
          l_ix    := :l_j - 1;
          l_code2 := ( :l_code2 + :la_t1_cnt[:l_ix] ) * 2;
        end if;
        la_t1_first[:l_j] := :l_code2;
        la_t1_offs[:l_j]  := :l_tot;
        l_tot := :l_tot + :la_t1_cnt[:l_j];
        la_pos[:l_j] := :l_tot - :la_t1_cnt[:l_j];
        l_j := :l_j + 1;
      end while;
      l_j := 1;
      while :l_j <= 19 do
        l_c := :la_cl[:l_j];
        if :l_c > 0 then
          la_pos[:l_c] := :la_pos[:l_c] + 1;
          l_ix := :la_pos[:l_c];
          la_t1_syms[:l_ix] := :l_j - 1;
        end if;
        l_j := :l_j + 1;
      end while;

      l_cl_n    := 0;
      l_lastlen := 0;
      while :l_cl_n < :l_nlit do

      l_code := 0;
      l_len  := 0;
      l_blc := -1;
      while :l_blc < 0 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_code := :l_code * 2 + :l_bit;
        l_len  := :l_len + 1;
        if :l_len > 15 then
          signal decode_err set message_text = 'LZH: invalid Huffman code';
        end if;
        if :la_t1_cnt[:l_len] > 0 then
          l_tmp := :l_code - :la_t1_first[:l_len];
          if :l_tmp >= 0 and :l_tmp < :la_t1_cnt[:l_len] then
            l_ix := :la_t1_offs[:l_len] + :l_tmp + 1;
            l_blc := :la_t1_syms[:l_ix];
          end if;
        end if;
      end while;
        if :l_blc < 16 then
          l_cl_n := :l_cl_n + 1;
          la_cl[:l_cl_n] := :l_blc;
          l_lastlen := :l_blc;
        else
          if :l_blc = 16 then

      l_rep := 0;
      l_k := 0;
      while :l_k < 2 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_rep := :l_rep + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
            l_rep  := :l_rep + 3;
            l_fill := :l_lastlen;
          elseif :l_blc = 17 then

      l_rep := 0;
      l_k := 0;
      while :l_k < 3 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_rep := :l_rep + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
            l_rep  := :l_rep + 3;
            l_fill := 0;
            l_lastlen := 0;
          else

      l_rep := 0;
      l_k := 0;
      while :l_k < 7 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_rep := :l_rep + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
            l_rep  := :l_rep + 11;
            l_fill := 0;
            l_lastlen := 0;
          end if;
          l_j2 := 1;
          while :l_j2 <= :l_rep do
            l_cl_n := :l_cl_n + 1;
            la_cl[:l_cl_n] := :l_fill;
            l_j2 := :l_j2 + 1;
          end while;
        end if;
      end while;

      l_j := 1;
      while :l_j <= 15 do
        la_t2_cnt[:l_j] := 0;
        l_j := :l_j + 1;
      end while;
      l_j := 1;
      while :l_j <= :l_nlit do
        l_c := :la_cl[:l_j];
        if :l_c > 0 then
          la_t2_cnt[:l_c] := :la_t2_cnt[:l_c] + 1;
        end if;
        l_j := :l_j + 1;
      end while;
      l_code2 := 0;
      l_tot   := 0;
      l_j := 1;
      while :l_j <= 15 do
        if :l_j > 1 then
          l_ix    := :l_j - 1;
          l_code2 := ( :l_code2 + :la_t2_cnt[:l_ix] ) * 2;
        end if;
        la_t2_first[:l_j] := :l_code2;
        la_t2_offs[:l_j]  := :l_tot;
        l_tot := :l_tot + :la_t2_cnt[:l_j];
        la_pos[:l_j] := :l_tot - :la_t2_cnt[:l_j];
        l_j := :l_j + 1;
      end while;
      l_j := 1;
      while :l_j <= :l_nlit do
        l_c := :la_cl[:l_j];
        if :l_c > 0 then
          la_pos[:l_c] := :la_pos[:l_c] + 1;
          l_ix := :la_pos[:l_c];
          la_t2_syms[:l_ix] := :l_j - 1;
        end if;
        l_j := :l_j + 1;
      end while;

      l_cl_n    := 0;
      l_lastlen := 0;
      while :l_cl_n < :l_ndist do

      l_code := 0;
      l_len  := 0;
      l_blc := -1;
      while :l_blc < 0 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_code := :l_code * 2 + :l_bit;
        l_len  := :l_len + 1;
        if :l_len > 15 then
          signal decode_err set message_text = 'LZH: invalid Huffman code';
        end if;
        if :la_t1_cnt[:l_len] > 0 then
          l_tmp := :l_code - :la_t1_first[:l_len];
          if :l_tmp >= 0 and :l_tmp < :la_t1_cnt[:l_len] then
            l_ix := :la_t1_offs[:l_len] + :l_tmp + 1;
            l_blc := :la_t1_syms[:l_ix];
          end if;
        end if;
      end while;
        if :l_blc < 16 then
          l_cl_n := :l_cl_n + 1;
          la_cl[:l_cl_n] := :l_blc;
          l_lastlen := :l_blc;
        else
          if :l_blc = 16 then

      l_rep := 0;
      l_k := 0;
      while :l_k < 2 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_rep := :l_rep + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
            l_rep  := :l_rep + 3;
            l_fill := :l_lastlen;
          elseif :l_blc = 17 then

      l_rep := 0;
      l_k := 0;
      while :l_k < 3 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_rep := :l_rep + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
            l_rep  := :l_rep + 3;
            l_fill := 0;
            l_lastlen := 0;
          else

      l_rep := 0;
      l_k := 0;
      while :l_k < 7 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_rep := :l_rep + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
            l_rep  := :l_rep + 11;
            l_fill := 0;
            l_lastlen := 0;
          end if;
          l_j2 := 1;
          while :l_j2 <= :l_rep do
            l_cl_n := :l_cl_n + 1;
            la_cl[:l_cl_n] := :l_fill;
            l_j2 := :l_j2 + 1;
          end while;
        end if;
      end while;

      l_j := 1;
      while :l_j <= 15 do
        la_t3_cnt[:l_j] := 0;
        l_j := :l_j + 1;
      end while;
      l_j := 1;
      while :l_j <= :l_ndist do
        l_c := :la_cl[:l_j];
        if :l_c > 0 then
          la_t3_cnt[:l_c] := :la_t3_cnt[:l_c] + 1;
        end if;
        l_j := :l_j + 1;
      end while;
      l_code2 := 0;
      l_tot   := 0;
      l_j := 1;
      while :l_j <= 15 do
        if :l_j > 1 then
          l_ix    := :l_j - 1;
          l_code2 := ( :l_code2 + :la_t3_cnt[:l_ix] ) * 2;
        end if;
        la_t3_first[:l_j] := :l_code2;
        la_t3_offs[:l_j]  := :l_tot;
        l_tot := :l_tot + :la_t3_cnt[:l_j];
        la_pos[:l_j] := :l_tot - :la_t3_cnt[:l_j];
        l_j := :l_j + 1;
      end while;
      l_j := 1;
      while :l_j <= :l_ndist do
        l_c := :la_cl[:l_j];
        if :l_c > 0 then
          la_pos[:l_c] := :la_pos[:l_c] + 1;
          l_ix := :la_pos[:l_c];
          la_t3_syms[:l_ix] := :l_j - 1;
        end if;
        l_j := :l_j + 1;
      end while;
            else
              signal decode_err set message_text = 'LZH: unknown block type';
            end if;

            l_eob := 0;
            while :l_eob = 0 do

      l_code := 0;
      l_len  := 0;
      l_sym := -1;
      while :l_sym < 0 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_code := :l_code * 2 + :l_bit;
        l_len  := :l_len + 1;
        if :l_len > 15 then
          signal decode_err set message_text = 'LZH: invalid Huffman code';
        end if;
        if :la_t2_cnt[:l_len] > 0 then
          l_tmp := :l_code - :la_t2_first[:l_len];
          if :l_tmp >= 0 and :l_tmp < :la_t2_cnt[:l_len] then
            l_ix := :la_t2_offs[:l_len] + :l_tmp + 1;
            l_sym := :la_t2_syms[:l_ix];
          end if;
        end if;
      end while;
              if :l_sym < 256 then
                l_out_n := :l_out_n + 1;
                la_out[:l_out_n] := :l_sym;
                l_ix := mod( :l_wc, 16384 ) + 1;
                la_win[:l_ix] := :l_sym;
                l_wc := :l_wc + 1;
              elseif :l_sym = 256 then
                l_eob := 1;
              else
                l_lc := :l_sym - 256;
                l_nb := :la_lenx[:l_lc];

      l_v1 := 0;
      l_k := 0;
      while :l_k < :l_nb do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_v1 := :l_v1 + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
                l_mlen := :la_lens[:l_lc] + :l_v1;

      l_code := 0;
      l_len  := 0;
      l_dc2 := -1;
      while :l_dc2 < 0 do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_code := :l_code * 2 + :l_bit;
        l_len  := :l_len + 1;
        if :l_len > 15 then
          signal decode_err set message_text = 'LZH: invalid Huffman code';
        end if;
        if :la_t3_cnt[:l_len] > 0 then
          l_tmp := :l_code - :la_t3_first[:l_len];
          if :l_tmp >= 0 and :l_tmp < :la_t3_cnt[:l_len] then
            l_ix := :la_t3_offs[:l_len] + :l_tmp + 1;
            l_dc2 := :la_t3_syms[:l_ix];
          end if;
        end if;
      end while;
                l_ix := :l_dc2 + 1;
                l_nb := :la_dstx[:l_ix];

      l_v1 := 0;
      l_k := 0;
      while :l_k < :l_nb do
        if :l_bcnt = 0 then
          l_bbuf := :la_in[:l_bpos];
          l_bpos := :l_bpos + 1;
          l_bcnt := 8;
        end if;
        l_bit  := mod( :l_bbuf, 2 );
        l_bbuf := ( :l_bbuf - :l_bit ) / 2;
        l_bcnt := :l_bcnt - 1;
        l_ix := :l_k + 1;
        l_v1 := :l_v1 + :l_bit * :la_pow2[:l_ix];
        l_k := :l_k + 1;
      end while;
                l_ix   := :l_dc2 + 1;
                l_dist := :la_dsts[:l_ix] + :l_v1;
                l_src := :l_wc - :l_dist;
                l_k2 := 1;
                while :l_k2 <= :l_mlen do
                  l_ix := mod( :l_src, 16384 ) + 1;
                  l_b  := :la_win[:l_ix];
                  l_out_n := :l_out_n + 1;
                  la_out[:l_out_n] := :l_b;
                  l_ix := mod( :l_wc, 16384 ) + 1;
                  la_win[:l_ix] := :l_b;
                  l_wc  := :l_wc + 1;
                  l_src := :l_src + 1;
                  l_k2  := :l_k2 + 1;
                end while;
              end if;
            end while;
          end while;
          if :l_out_n != :l_expect then
            signal decode_err set message_text = 'LZH: length mismatch after decompression';
          end if;
          else
            l_j := 17;
            while :l_j <= :l_in_n do
              l_out_n := :l_out_n + 1;
              la_out[:l_out_n] := :la_in[:l_j];
              l_j := :l_j + 1;
            end while;
          end if;

        l_p       := 1;
        l_nf      := 0;
        l_rowsum  := 0;
        l_lineno  := 0;
        while :l_p <= :l_out_n do
          l_m := :la_out[:l_p];
          if :l_m = 3 then
            l_rowsum := 0;
            l_nf     := 0;
            if :l_ver >= 6 then
              l_ix := :l_p + 11;
              l_namelen := :la_out[:l_ix];
              l_p := :l_p + 32 + :l_namelen * :l_csize;
            elseif :l_ver >= 4 then
              l_ix := :l_p + 6;
              l_namelen := :la_out[:l_ix];
              l_p := :l_p + 15 + :l_namelen * :l_csize;
            else
              l_ix := :l_p + 6;
              l_namelen := :la_out[:l_ix];
              l_p := :l_p + 7 + :l_namelen;
            end if;
          elseif :l_m = 160 or :l_m = 161 or :l_m = 173 or :l_m = 174 then
            if :l_ver >= 6 then
              l_p := :l_p + 7;
            else
              l_p := :l_p + 4;
            end if;
          elseif :l_m = 170 then
            if :l_ver >= 6 then
              l_ix := :l_p + 3;
              l_v1 := :la_out[:l_ix];
              l_ix := :l_p + 4;
              l_v1 := :l_v1 * 256 + :la_out[:l_ix];
              l_ix := :l_p + 5;
              l_v1 := :l_v1 * 256 + :la_out[:l_ix];
              l_ix := :l_p + 6;
              l_v1 := :l_v1 * 256 + :la_out[:l_ix];
              l_p := :l_p + 7;
            else
              l_ix := :l_p + 1;
              l_v1 := :la_out[:l_ix];
              l_ix := :l_p + 2;
              l_v1 := :l_v1 * 256 + :la_out[:l_ix];
              l_ix := :l_p + 3;
              l_v1 := ( :l_v1 * 256 + :la_out[:l_ix] ) * :l_csize;
              l_p := :l_p + 4;
            end if;
            l_rowsum := :l_rowsum + :l_v1;
          elseif :l_m = 190 then
            l_p := :l_p + 9;
          elseif :l_m = 188 then
            l_ix := :l_p + 1;
            l_rowlen := :la_out[:l_ix];
            l_ix := :l_p + 2;
            l_rowlen := :l_rowlen * 256 + :la_out[:l_ix];
            l_ix := :l_p + 3;
            l_rowlen := :l_rowlen * 256 + :la_out[:l_ix];
            l_ix := :l_p + 4;
            l_rowlen := :l_rowlen * 256 + :la_out[:l_ix];
            l_rowstart := :l_p + 5;

      l_lineno := :l_lineno + 1;
      l_fmt    := '';
      l_line   := '';
      l_chpos  := :l_rowstart;
      l_cc     := :l_rowlen / :l_csize;
      l_j2 := 1;
      while :l_j2 <= :l_cc do
        if :l_csize = 2 then
          l_ix     := :l_chpos + 1;
          l_chcode := :la_out[:l_chpos] + :la_out[:l_ix] * 256;
          l_chpos  := :l_chpos + 2;
        else
          l_chcode := :la_out[:l_chpos];
          l_chpos  := :l_chpos + 1;
          if :l_cp = '1500' and :l_chcode >= 161 then
            if :l_chcode = 173 then
              l_chcode := 173;
            elseif :l_chcode = 240 then
              l_chcode := 8470;
            elseif :l_chcode = 253 then
              l_chcode := 167;
            else
              l_chcode := :l_chcode + 864;
            end if;
          end if;
        end if;
        if :l_chcode > 0 then
          if :l_j2 <= 2 then
            l_fmt := :l_fmt || nchar( :l_chcode );
          else
            l_line := :l_line || nchar( :l_chcode );
          end if;
        end if;
        l_j2 := :l_j2 + 1;
      end while;
      l_o_n := :l_o_n + 1;
      la_o_object[:l_o_n] := :la_g_object[:l_i];
      la_o_name[:l_o_n]   := :la_g_name[:l_i];
      la_o_id[:l_o_n]     := :la_g_id[:l_i];
      la_o_spras[:l_o_n]  := :la_g_spras[:l_i];
      la_o_line[:l_o_n]   := :l_lineno;
      la_o_fmt[:l_o_n]    := rtrim( :l_fmt );
      la_o_text[:l_o_n]   := rtrim( :l_line );
            l_p := :l_p + 5 + :l_rowlen;
          elseif :l_m = 189 or :l_m = 191 then
            l_p := :l_p + 1;
          elseif :l_m = 187 then
            l_rowlen   := :l_rowsum;
            l_rowstart := :l_p + 1;

      l_lineno := :l_lineno + 1;
      l_fmt    := '';
      l_line   := '';
      l_chpos  := :l_rowstart;
      l_cc     := :l_rowlen / :l_csize;
      l_j2 := 1;
      while :l_j2 <= :l_cc do
        if :l_csize = 2 then
          l_ix     := :l_chpos + 1;
          l_chcode := :la_out[:l_chpos] + :la_out[:l_ix] * 256;
          l_chpos  := :l_chpos + 2;
        else
          l_chcode := :la_out[:l_chpos];
          l_chpos  := :l_chpos + 1;
          if :l_cp = '1500' and :l_chcode >= 161 then
            if :l_chcode = 173 then
              l_chcode := 173;
            elseif :l_chcode = 240 then
              l_chcode := 8470;
            elseif :l_chcode = 253 then
              l_chcode := 167;
            else
              l_chcode := :l_chcode + 864;
            end if;
          end if;
        end if;
        if :l_chcode > 0 then
          if :l_j2 <= 2 then
            l_fmt := :l_fmt || nchar( :l_chcode );
          else
            l_line := :l_line || nchar( :l_chcode );
          end if;
        end if;
        l_j2 := :l_j2 + 1;
      end while;
      l_o_n := :l_o_n + 1;
      la_o_object[:l_o_n] := :la_g_object[:l_i];
      la_o_name[:l_o_n]   := :la_g_name[:l_i];
      la_o_id[:l_o_n]     := :la_g_id[:l_i];
      la_o_spras[:l_o_n]  := :la_g_spras[:l_i];
      la_o_line[:l_o_n]   := :l_lineno;
      la_o_fmt[:l_o_n]    := rtrim( :l_fmt );
      la_o_text[:l_o_n]   := rtrim( :l_line );
            l_p := :l_p + 1 + :l_rowlen;
          elseif :l_m = 4 or :l_m = 0 then
            l_p := :l_p + 1;
          else
            signal decode_err set message_text = 'STXL: unknown container marker ' || :l_m;
          end if;
        end while;
          l_in_n := 0;
        elseif :l_grp_new = 1 then
          l_in_n := 0;
        end if;

        l_i := :l_i + 1;
      end while;

    end if;


    if :l_o_n > 0 then
      lt_out = unnest( :la_o_object, :la_o_name, :la_o_id, :la_o_spras,
                       :la_o_line, :la_o_fmt, :la_o_text )
               as ( tdobject, tdname, tdid, tdspras, line_no, tdformat, tdline );
      et_lines = select tdobject, tdname, tdid, tdspras, line_no, tdformat, tdline
                   from :lt_out
                  order by tdobject, tdname, tdid, tdspras, line_no;
    else
      et_lines = select
                    cast( '' as nvarchar(10) )  as tdobject,
                    cast( '' as nvarchar(70) )  as tdname,
                    cast( '' as nvarchar(4) )   as tdid,
                    cast( '' as nvarchar(1) )   as tdspras,
                    cast( 0  as integer )       as line_no,
                    cast( '' as nvarchar(2) )   as tdformat,
                    cast( '' as nvarchar(132) ) as tdline
               from dummy where 1 = 0;
    end if;

  endmethod.

endclass.
