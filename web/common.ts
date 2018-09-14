"use strict";
import Highcharts from "highcharts";

export function assert<T>(x: undefined|null|false|T): T {
  if (!x)
    throw new Error("assertion failure");
  return x;
}

export type Dict<T> = { [name: string]: T };

export type Field = {
  name: string,
  type: string,
  title: string,
  descr?: null|string,
  units?: null|string,
  top?: boolean,
  disp: boolean,
  base: 'f'|'i'|'b'|'s',
  terms?: boolean,
  enum?: null|string[],
  dict?: null|string
};

export type Catalog = {
  name: string,
  title: string,
  descr: null|string,
  bulk: string[],
  fields: Field[],
  count?: number,
};

export type AggrStats = {
  min: number,
  max: number,
  avg: number
};
export type AggrTerms<T> = {
  buckets: Array<{ key: T, doc_count: number, hist?: AggrTerms<any> }>
}

export type Aggr = AggrStats|AggrTerms<string|number>;

export type CatalogResponse = {
  hits: {
    total: number,
    hits: Dict<any>[]
  },
  aggregations?: Dict<Aggr>,
  histsize: number[]
};

export function fill_select_terms(s: HTMLSelectElement, f: Field, a: AggrTerms<string>) {
  s.add(document.createElement('option'));
  for (let b of a.buckets) {
    const opt = document.createElement('option');
    opt.value = b.key;
    if (f.enum && b.key in f.enum)
      opt.text = f.enum[<any>b.key];
    else
      opt.text = b.key;
    opt.text += ' (' + b.doc_count + ')';
    s.add(opt);
  }
  s.disabled = false;
}

export function field_option(f: Field): HTMLOptionElement {
  const o = document.createElement('option');
  o.value = f.name;
  o.text = f.title;
  if (f.descr)
    o.title = f.descr;
  return o;
}

const axisProto = (<any>Highcharts).Axis.prototype;
axisProto.allowNegativeLog = true;
axisProto.log2lin = function (x: number) {
  return x >= 1 ? Math.log10(x) : -1;
};
axisProto.lin2log = function (x: number) {
  return Math.round(Math.pow(10, x));
};

export function toggle_log(chart: Highcharts.ChartObject) {
  const axis = <Highcharts.AxisObject>chart.get('tog');
  if ((<any>axis).userOptions.type !== 'linear') {
    axis.update({
      min: 0,
      type: 'linear'
    });
  }
  else {
    axis.update({
      min: 0.1, 
      type: 'logarithmic'
    });
  }
}
