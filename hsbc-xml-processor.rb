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
STR_ABONO_CASA = 'Mantenimiento Casa'
ID_MOVS = [
  {
    desc: "#{STR_ABONO_CASA} 4",
    categoria: :pago_mto,
    tipo: :ingreso,
    casa: 'Casa 4',
    regex: /ABONO BPI DE CUENTA/i,
    importes: [3_500.0]
  },
  {
    desc: "#{STR_ABONO_CASA} %<num_casa>s",
    categoria: :pago_mto,
    tipo: :ingreso,
    casa: 'Casa %<num_casa>s',
    regex: /(?<casa>ksa|ka[sd]a|ca[sd]a|c)\s*(?<num_casa>[1-6])/i,
    capturas: [:num_casa],
    importes: [3_500.0]
  },
  {
    desc: "#{STR_ABONO_CASA} (sin identificar)",
    categoria: :pago_mto,
    tipo: :ingreso,
    casa: 'Sin identificar',
    regex: /(PAGO\s*)?(mantenimiento|mant|mto)/i,
    importes: [3_500.0]
  },
  {
    desc: 'Compra en Amazon',
    categoria: :extraord,
    tipo: :gasto,
    regex: /amazon/i
  },
  {
    desc: 'CFE',
    categoria: :cfe,
    tipo: :gasto,
    regex: /cfe/i
  },
  {
    desc: 'Conserje',
    categoria: :conserje,
    tipo: :gasto,
    regex: /eder/i
  },
  {
    desc: 'Servicio de Limpieza',
    categoria: :conserje,
    tipo: :gasto,
    regex: /impieza/i
  },
  {
    desc: 'Retiro de cajero',
    categoria: :caja_chica,
    tipo: :gasto,
    regex: /retiro cajero/i
  },
  {
    desc: 'Pago Mantenimiento de la Cerrada',
    categoria: :mto_cgm,
    tipo: :gasto,
    regex: /(mto|mantenimiento.+cgm\s*13)|(cgm\s*13.+mto|mantenimiento)/i,
    importes: [1_800.0]
  },
  {
    desc: 'Compra en Mercado Libre',
    categoria: :extraord,
    tipo: :gasto,
    regex: /merpago/i
  },
  {
    desc: 'Compra o pago de servicio',
    categoria: :otros,
    tipo: :gasto,
    regex: /pago/i
  },
  {
    desc: 'Transferencia',
    categoria: :otros,
    tipo: :gasto,
    regex: /cgo/i
  }
].freeze
REGEX_MES = /[\s\b](?<mes>#{MESES.compact.join('|')}|#{MESES_ABR.keys.compact.join('|')})/i

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

def extraer_mes_movimiento(desc, fecha)
  desc.match(REGEX_MES) do |m|
    mes = m[:mes].downcase.to_sym
    return MESES_ABR[mes] || mes if m[:mes].length == 3

    return mes
  end

  MESES[fecha.month] || :nd
end

def extraer_movs(xml_doc)
  movs = []

  (xml_doc.xpath(*XPATH_MOVS) || []).each do |movimiento|
    fecha = Date.parse(movimiento['fecha'])
    movs << {
      fecha:,
      desc_mov: movimiento['descripcion'],
      importe: movimiento['importe'].to_f,
      mes: extraer_mes_movimiento(movimiento['descripcion'], fecha)
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

def etiquetar_mov(concepto)
  ID_MOVS.each do |mov|
    concepto[:desc_mov].match(mov[:regex]) do |m|
      mov_simplificado = mov.except(:regex, :capturas, :importes)

      if mov[:capturas]
        hsh = mov[:capturas].reduce({}) { |acc, val| acc.merge(val => m[val]) }
        mov_simplificado[:desc] = format(mov[:desc], hsh)
        mov_simplificado[:casa] = format(mov[:casa], hsh)
      end

      if mov.key?(:importes)

        return concepto.merge(mov_simplificado) if mov[:importes].include?(concepto[:importe])

        next
      end

      return concepto.merge(mov_simplificado)
    end
  end

  nil
end

def procesar_conceptos(conceptos)
  conceptos.map do |c|
    etiquetar_mov(c) || c.merge({ desc: :nd, categoria: :nd, tipo: :nd })
  end
end

def agregar_a_edo_cta(conceptos, edo_cta)
  conceptos.each do |concepto|
    case concepto[:tipo]
    when :gasto
      edo_cta[:movs][:gastos][concepto[:categoria]] << concepto.merge(importe: concepto[:importe] * -1)
    when :ingreso
      edo_cta[:movs][:pago_mto][concepto[:casa]] << concepto
    else
      edo_cta[:movs][:sin_categoria] << concepto
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
