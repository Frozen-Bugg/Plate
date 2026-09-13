/// Just enough of Deno's globals to typecheck the Edge Function on Node.
///
/// There is no Deno on this machine and `supabase functions serve` needs
/// Docker, so the alternative to this file is finding a typo during a deploy.
/// It is deliberately minimal: it asserts the shape of what the function
/// actually uses, and nothing else. It is not a Deno polyfill and must never
/// grow into one — if the function starts needing more of Deno than this, that
/// is a sign the logic belongs in `src/`, where the real tests are.

declare namespace Deno {
  function serve(handler: (request: Request) => Response | Promise<Response>): unknown;

  const env: {
    toObject(): Record<string, string>;
    get(key: string): string | undefined;
  };
}
