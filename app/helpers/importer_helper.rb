# -*- coding: utf-8 -*-

require "nkf"

module ImporterHelper
  ENCODINGS_FOR_SELECT = [ [ "UTF8", "U" ], [ "EUC", "EUC" ], [ "SJIS", "S" ], [ "None", "N" ] ]
  ENCODING_CONVERTER = {
    "U"   => nil,  # Need not to convert
    "EUC" => Proc.new{ |str| NKF.nkf("-Ewm0", str) },
    "S"   => Proc.new{ |str| NKF.nkf("-Swm0", str) },
    "N"   => nil  # Need not to convert
  }

  def importer_encodings_for_select
    return ENCODINGS_FOR_SELECT
  end

  def importer_encoding_converter(enc_param)
    return ENCODING_CONVERTER[enc_param]
  end
end

