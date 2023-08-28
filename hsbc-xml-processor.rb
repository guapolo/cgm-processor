#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'nokogiri'
  gem 'oj'
end

require 'date'
require 'nokogiri'
require 'oj'

Oj.default_options = Oj.default_options.merge(mode: :compat)

DIR_XMLS_HSBC = "#{ENV.fetch('DIR_XMLS_HSBC', nil) || 'xmls_hsbc'}/*.xml".freeze
DIR_JSON_EDOS_CTA = 'edos_cta'
XPATH_MOVS = [
  '//DG:MovimientosDelCliente',
  { 'DG' => 'http://www.hsbc.com.mx/schema/DG' }
].freeze
MESES = [
  nil,
  :enero,
  :febrero,
  :marzo,
  :abril,
  :mayo,
  :junio,
  :julio,
  :agosto,
  :septiembre,
  :octubre,
  :noviembre,
  :diciembre
].freeze
MESES_ABR = Hash[MESES.compact.map { |m| [:"#{m[0..2]}", m.to_sym] }]
MANTENIMIENTO_MENSUAL = 3_500.00
MANTENIMIENTO_CGM13 = 1_800.00
ID_CARGOS = {
  'AMAZON' => { desc: 'Compra en Amazon', categoria: :extraord },
  'CFE' => { desc: 'CFE', categoria: :cfe },
  'EDER' => { desc: 'Conserje', categoria: :conserje },
  'impieza' => { desc: 'Servicio de Limpieza', categoria: :conserje },
  'RETIRO CAJERO' => { desc: 'Retiro cajero', categoria: :caja_chica },
  'CGM' => { desc: 'Pago Mantenimiento Cerrada', categoria: :mto_cgm },
  'CGM 13' => { desc: 'Pago Mantenimiento Cerrada', categoria: :mto_cgm },
  'CGM13' => { desc: 'Pago Mantenimiento Cerrada', categoria: :mto_cgm },
  'MERPAGO' => { desc: 'Compra en Mercado Libre', categoria: :extraord },
  'PAGO' => { desc: 'Compra o pago de servicio', categoria: :otros },
  'CGO' => { desc: 'Transferencia', categoria: :otros }
}.freeze
REGEX_MTO_CASA = /(?<casa>ksa|ka[sd]a|ca[sd]a|c)\s*(?<num_casa>[1-6])/i
REGEX_PAGO_MTO_SIN_ID = /(PAGO\s*)?(mantenimiento|mant|mto)/i
REGEX_ABONO_HSBC = /ABONO BPI DE CUENTA/i
REGEX_MES = /[\s\b](?<mes>#{MESES.compact.join('|')}|#{MESES_ABR.keys.compact.join('|')})/i
STR_ABONO_CASA = 'Mantenimiento Casa'

fecha_actual = Date.today
edo_cta = {
  mes: fecha_actual.month,
  anio: fecha_actual.year,
  fecha: fecha_actual,
  movs: {
    pago_mto: {
      'Casa 1' => [],
      'Casa 2' => [],
      'Casa 3' => [],
      'Casa 4' => [],
      'Casa 5' => [],
      'Casa 6' => [],
      'Sin identificar' => []
    },
    gastos: {
      cfe: [],
      conserje: [],
      mto_cgm: [],
      otros: [],
      extraord: [],
      pagos_efe: []
    },
    sin_categoria: []
  },
  caja_chica: {
    saldo: 0
  },
  saldo_inicial_cta: {
    enero: 0,
    febrero: 0,
    marzo: 0,
    abril: 0,
    mayo: 0,
    junio: 0,
    julio: 0,
    agosto: 0,
    septiembre: 0,
    octubre: 0,
    noviembre: 0,
    diciembre: 0
  },
  saldo_cta_hoy: 0
}.freeze

def extraer_mes_movimiento(desc)
  desc.match(REGEX_MES) do |m|
    mes = m[:mes].downcase.to_sym
    return MESES_ABR[mes] || mes if m[:mes].length > 3

    return mes
  end

  :nd
end

def extraer_movs(xml_doc)
  movs = []
  (xml_doc.xpath(*XPATH_MOVS) || []).each do |movimiento|
    movs << {
      fecha: Date.parse(movimiento['fecha']),
      desc_mov: movimiento['descripcion'],
      importe: movimiento['importe'].to_f,
      mes: extraer_mes_movimiento(movimiento['descripcion'])
    }
  end

  movs
end

def extraer_fecha(xml_doc)
  fecha_xml = xml_doc.at_xpath('//cfdi:Comprobante')['Fecha']
  fecha = Date.parse(fecha_xml)
  fecha_mes_anterior = fecha.prev_month
  { mes: fecha_mes_anterior.month, anio: fecha_mes_anterior.year, fecha: }
end

def renombrar_archivo(archivo, mes, anio)
  File.rename(archivo, "#{File.dirname(archivo)}/#{anio}.#{mes.to_s.rjust(2, '0')}.edo_cta.xml")
end

def extraer_conceptos(archivo)
  conceptos = {}
  xml_doc = File.open(archivo) { |f| Nokogiri::XML(f) }
  conceptos = conceptos.merge(extraer_fecha(xml_doc))
  conceptos[:movs] = extraer_movs(xml_doc)

  renombrar_archivo(archivo, conceptos[:mes], conceptos[:anio])

  conceptos
end

def etiquetar_gasto(concepto)
  ID_CARGOS.each do |id, desc|
    if concepto[:desc_mov].match?(/#{id}/i)
      return concepto.merge(desc).merge(tipo: :gasto, importe: concepto[:importe] * -1)
    end
  end

  nil
end

def etiquetar_pago_mto_c4(concepto)
  if concepto[:desc_mov].match?(REGEX_ABONO_HSBC)
    return concepto.merge({
                            desc: "#{STR_ABONO_CASA} 4",
                            categoria: :pago_mto,
                            tipo: :ingreso,
                            casa: 'Casa 4'
                          })
  end

  nil
end

def etiquetar_ingreso_casa(concepto)
  concepto[:desc_mov].match(REGEX_MTO_CASA) do |m|
    return concepto.merge({
                            desc: "#{STR_ABONO_CASA} #{m[:num_casa]}",
                            categoria: :pago_mto,
                            tipo: :ingreso,
                            casa: "Casa #{m[:num_casa]}"
                          })
  end

  nil
end

def etiquetar_ingreso_sin_identificar(concepto)
  if concepto[:desc_mov].match?(REGEX_PAGO_MTO_SIN_ID) && concepto[:importe] == MANTENIMIENTO_MENSUAL
    return concepto.merge({
                            desc: "#{STR_ABONO_CASA} (sin identificar)",
                            categoria: :pago_mto,
                            tipo: :ingreso,
                            casa: 'Sin identificar'
                          })
  end

  nil
end

def etiquetar_ingreso(concepto)
  etiquetar_ingreso_casa(concepto) ||
    etiquetar_ingreso_sin_identificar(concepto)
end

def procesar_conceptos(conceptos)
  conceptos.map do |c|
    etiquetar_pago_mto_c4(c) ||
      etiquetar_ingreso(c) ||
      etiquetar_gasto(c) ||
      c.merge({ desc: :nd, categoria: :nd, tipo: :nd })
  end
end

def agregar_a_edo_cta(movs, edo_cta)
  movs.each do |mov|
    case mov[:tipo]
    when :gasto
      edo_cta[:movs][:gastos][mov[:categoria]] << mov
    when :ingreso
      edo_cta[:movs][:pago_mto][mov[:casa]] << mov
    else
      edo_cta[:movs][:sin_categoria] << mov
    end
  end
end

def nombre_archivo_edo_cta(edo_cta)
  "#{edo_cta[:anio]}.#{edo_cta[:mes].to_s.rjust(2, '0')}.edo_cta"
end

def generar_json_edo_cta(edo_cta)
  json = Oj.dump(edo_cta)

  File.write(
    "#{DIR_JSON_EDOS_CTA}/#{nombre_archivo_edo_cta(edo_cta)}.json",
    json
  )

  json
end

Dir[DIR_XMLS_HSBC].each do |archivo|
  conceptos = extraer_conceptos(archivo)
  movs = procesar_conceptos(conceptos[:movs]).sort_by { |c| c[:fecha] }

  agregar_a_edo_cta(movs, edo_cta)

  puts generar_json_edo_cta(edo_cta)
end
