/**
 * Vercel Edge Function - API Proxy for CruiseApp
 * Caches hot endpoints at the edge for <20ms response times.
 */

export const config = {
  runtime: 'edge',
};

const RAILWAY_BACKEND = 'https://cruiseapp2-production.up.railway.app';

export default async function handler(request: any): Promise<any> {
  const url = new URL(request.url);
  const path = url.pathname;
  const searchParams = url.search;
  
  const targetUrl = `${RAILWAY_BACKEND}${path}${searchParams}`;
  
  // Proxy request to Railway backend
  const backendResponse = await fetch(targetUrl, {
    method: request.method,
    headers: request.headers,
    body: request.method !== 'GET' && request.method !== 'HEAD' ? request.body : undefined,
  });
  
  return new Response(backendResponse.body, {
    status: backendResponse.status,
    statusText: backendResponse.statusText,
    headers: backendResponse.headers,
  });
}
