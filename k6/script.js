import http from 'k6/http';
import { check } from 'k6';

const quick = __ENV.QUICK === 'true';

const fullStages = [
  { duration: '20s', target: 100 },
  { duration: '30s', target: 100 },
  { duration: '20s', target: 300 },
  { duration: '30s', target: 300 },
  { duration: '20s', target: 500 },
  { duration: '30s', target: 500 },
  { duration: '10s', target: 0 },
];

const quickStages = [
  { duration: '5s', target: 10 },
  { duration: '5s', target: 10 },
  { duration: '3s', target: 0 },
];

export const options = {
  scenarios: {
    ramping: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: quick ? quickStages : fullStages,
      gracefulRampDown: '5s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://api1:8080';

export default function () {
  const res = http.get(`${BASE_URL}/api1`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}
