const BACKEND = "https://pankosmia-web.up.railway.app";

export default async (request: Request) => {
  const url = new URL(request.url);
  const backendUrl = `${BACKEND}/notifications${url.search}`;

  const headers = new Headers(request.headers);
  headers.set("Host", new URL(BACKEND).host);

  const response = await fetch(backendUrl, {
    headers,
  });

  return new Response(response.body, {
    status: response.status,
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    },
  });
};

export const config = { path: "/notifications" };
