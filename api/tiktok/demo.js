export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).send('Method Not Allowed');

  const connected = /(?:^|;\s*)tiktok_demo_session=/.test(req.headers.cookie || '');
  const body = connected
    ? `<p><strong>Step 1 complete:</strong> TikTok account authorized through Login Kit.</p>
       <p><strong>Step 2:</strong> Select a small MP4 video and send it to TikTok as a draft using Content Posting API / <code>video.upload</code>.</p>
       <input id="file" type="file" accept="video/mp4,video/quicktime" />
       <button id="upload" type="button">Upload demo video to TikTok</button>
       <pre id="result"></pre>
       <script>
         const button = document.getElementById('upload');
         const fileInput = document.getElementById('file');
         const result = document.getElementById('result');
         button.addEventListener('click', async () => {
           const file = fileInput.files && fileInput.files[0];
           if (!file) { result.textContent = 'Select an MP4/MOV file first.'; return; }
           if (file.size > 4 * 1024 * 1024) { result.textContent = 'For this serverless demo, use a file smaller than 4 MB.'; return; }
           button.disabled = true;
           result.textContent = 'Uploading…';
           try {
             const response = await fetch('/api/tiktok/upload', {
               method: 'POST',
               headers: {
                 'Content-Type': file.type || 'video/mp4',
                 'X-Video-Size': String(file.size),
               },
               body: file,
             });
             const data = await response.json();
             result.textContent = JSON.stringify(data, null, 2);
           } catch (err) {
             result.textContent = String(err && err.message || err);
           } finally {
             button.disabled = false;
           }
         });
       </script>`
    : `<p>No TikTok demo session is connected yet.</p><p><a href="/api/tiktok/oauth/start">Start TikTok Login Kit authorization</a></p>`;

  return res.status(200).send(`<!doctype html><html><head><meta charset="utf-8"><meta name="robots" content="noindex,nofollow"><title>Cygnus TikTok Integration Demo</title></head><body><h1>Cygnus Academy AI — TikTok integration demo</h1><p>This page demonstrates the two requested capabilities: Login Kit and Content Posting API.</p>${body}</body></html>`);
}
