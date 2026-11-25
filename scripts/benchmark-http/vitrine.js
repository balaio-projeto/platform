// Carga concorrente na vitrine (item 3.2): GET /api/v1/pecas, com usuários virtuais constantes.
import http from 'k6/http';
import { check } from 'k6';

const base = __ENV.BASE || 'http://host.docker.internal:8081';
const vus = parseInt(__ENV.VUS || '1', 10);
const duracao = __ENV.DURACAO || '30s';
const rep = __ENV.REP || '0';

export const options = {
  scenarios: { vitrine: { executor: 'constant-vus', vus: vus, duration: duracao } },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)'],
};

export default function () {
  const r = http.get(`${base}/api/v1/pecas?tamanho=12`);
  check(r, { 'status 200': (x) => x.status === 200 });
}

export function handleSummary(data) {
  const m = data.metrics;
  const resultado = {
    vus: vus,
    repeticao: rep,
    duracao: duracao,
    requisicoes: m.http_reqs.values.count,
    vazao_por_s: m.http_reqs.values.rate,
    p50_ms: m.http_req_duration.values.med,
    p95_ms: m.http_req_duration.values['p(95)'],
    p99_ms: m.http_req_duration.values['p(99)'],
    falhas_taxa: m.http_req_failed.values.rate,
  };
  return { [`/out/vitrine-vus${vus}-rep${rep}.json`]: JSON.stringify(resultado) };
}
