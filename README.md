# Prj_ML_VisualizacionDeDatosMedianteMotorDeCharting

Proyecto en Perl orientado al análisis técnico, visualización de mercado y preparación de datos para un flujo de Machine Learning sobre series temporales financieras.

## Descripción general

Este repositorio combina tres bloques principales:

1. **Motor de visualización de gráficos** con interfaz gráfica en Tk.
2. **Sistema de indicadores técnicos y overlays** para estudiar estructura de mercado, liquidez, pivotes, volumen y VWAP.
3. **Pipeline de Machine Learning** para extraer características causales desde velas OHLCV y entrenar un modelo LSTM para detectar patrones de “ghosts in swings”.

En la práctica, el proyecto permite cargar datos CSV de mercado, construir timeframes, calcular indicadores, visualizar señales sobre el chart y generar datasets de entrenamiento/predicción sin fuga de información futura.

## Qué resuelve el proyecto

El objetivo del proyecto es facilitar el estudio y la automatización de análisis de mercado en cuatro niveles:

- **Lectura y normalización de datos OHLCV**.
- **Cálculo de indicadores técnicos y conceptos SMC**.
- **Visualización interactiva con overlays** para inspección manual.
- **Extracción de features y entrenamiento supervisado** para predicción de eventos de corto plazo.

## Componentes principales

### 1. `market.pl`

Es la aplicación principal. Carga un CSV de velas, construye agregaciones por timeframe y muestra un chart interactivo con:

- ATR
- ZigZag externo e interno
- Liquidez y estados SWEEP/GRAB/RUN
- Estructura SMC: BOS, CHoCH, FVG, OB
- Market Regime
- Strategy Builder
- Volume Profile
- Anchored VWAP
- Pivot Missed Reversal
- Herramientas auxiliares como canal de regresión y Fibonacci manual/automático

### 2. `ml/extract_features.pl`

Script de extracción causal de características. Toma un CSV de entrada y genera otro CSV listo para entrenamiento, usando:

- eventos observables en replay de 1 minuto
- distancias a niveles de mercado en múltiples marcos temporales
- targets `Y_3m`, `Y_5m`, `Y_10m`, `Y_15m`

### 3. Módulos `Market::*`

El repositorio contiene varios módulos responsables de:

- estructurar datos de mercado
- calcular indicadores
- construir overlays
- orquestar el render del chart
- preparar el pipeline de ML

## Flujo de trabajo

1. Se carga un CSV de velas.
2. Se construyen los timeframes agregados.
3. Se calculan indicadores y estructuras de mercado.
4. La interfaz permite revisar el comportamiento visual del precio.
5. El pipeline ML extrae features causales.
6. Se entrena y evalúa el modelo con datos separados por período.

## Datos y archivos relevantes

Según el README y scripts del proyecto, los archivos clave son:

- `market.pl` — interfaz principal del chart.
- `ml/extract_features.pl` — extracción de características.
- `ml/run_all.sh` — orquestación del pipeline ML.
- `2026_Abril-Junio.csv` — conjunto de entrenamiento/ajuste.
- `2026_07_24.csv` — conjunto de prueba/visualización por defecto.

## Cómo ejecutar pruebas

Las pruebas del motor se ejecutan sin interfaz gráfica ni datos CSV externos:

```bash
prove -I. -lr t
```

## Evaluación de señales

`Market::Indicators::Strategy_Builder` expone `run_backtest()`. Una señal confirmada en la vela `i` entra únicamente en la apertura de `i + 1`; no se debe usar el máximo o mínimo de la vela que la originó.

```perl
my $result = $strategy->run_backtest(
    initial_capital   => 10_000,
    risk_per_trade    => 0.01,
    stop_atr_multiple => 1.5,
    reward_risk       => 2,
    commission_bps    => 1,
    slippage_bps      => 1,
);
```

## Pipeline ML final

El pipeline supervisado final usa exclusivamente:

- `2026_Abril-Junio.csv` para seleccionar y ajustar la red LSTM
- `2026_07_24.csv` como test externo
- características causales derivadas del replay
- cuatro salidas simultáneas: `Y_3m`, `Y_5m`, `Y_10m` y `Y_15m`

Ejecución completa:

```bash
bash ml/run_all.sh
```

## Artefactos generados

El entrenamiento guarda por separado:

- `ml/model_fantasmas_lstm.npz`
- `ml/scaler_params_lstm.npz`
- `ml/model_config_lstm.json`
- `ml/training_report_lstm.json`

El evaluador genera:

- `ml/test_metrics_lstm.json`

## Requisitos funcionales del proyecto

Para que el sistema funcione correctamente, el repositorio debe conservar:

- consistencia en el formato CSV de entrada
- separación entre entrenamiento y prueba
- extracción causal sin fuga de futuro
- indicadores reproducibles y testeados
- sincronización entre overlays, chart y pipeline ML

## Uso básico

Abrir la visualización principal:

```bash
perl market.pl ruta/al/archivo.csv
```

Ejecutar extracción de features:

```bash
perl ml/extract_features.pl entrada.csv salida.csv
```

## En resumen

Este proyecto es una plataforma de análisis de mercado en Perl que integra visualización interactiva, indicadores técnicos avanzados y un pipeline de Machine Learning para estudiar patrones de precio y generar predicciones a partir de datos OHLCV.
