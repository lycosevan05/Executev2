import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const { getSession, storageFrom, getPublicUrl } = vi.hoisted(() => ({
  getSession: vi.fn(),
  storageFrom: vi.fn(),
  getPublicUrl: vi.fn(),
}));

vi.mock('@supabase/supabase-js', () => ({
  createClient: () => ({
    auth: { getSession },
    storage: { from: storageFrom },
  }),
}));

const projectURL = 'https://example.supabase.co/';
const ownerID = '4fd2e61d-73bb-4afd-9e8a-93b231a32836';
const accessToken = 'signed-in-access-token';
const file = new File(['fixture'], 'meal photo.jpg', { type: 'image/jpeg' });

describe('Core.UploadFile guarded storage', () => {
  let fetchUpload;
  let UploadFile;

  beforeEach(async () => {
    vi.resetModules();
    vi.resetAllMocks();
    vi.stubEnv('VITE_SUPABASE_URL', projectURL);
    vi.stubEnv('VITE_SUPABASE_ANON_KEY', 'test-anon-key');
    vi.stubEnv('VITE_SUPABASE_UPLOAD_BUCKET', 'uploads');
    getSession.mockResolvedValue({
      data: { session: { access_token: accessToken, user: { id: ownerID } } },
      error: null,
    });
    storageFrom.mockReturnValue({ getPublicUrl });
    getPublicUrl.mockImplementation(path => ({ data: { publicUrl: `https://example.supabase.co/public/${path}` } }));
    fetchUpload = vi.fn(async url => Response.json({ path: url.searchParams.get('path') }));
    vi.stubGlobal('fetch', fetchUpload);

    const { backend } = await import('./backendClient');
    UploadFile = backend.integrations.Core.UploadFile;
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it('uses the persisted session for the owner and bearer token and sends the original file', async () => {
    getSession.mockResolvedValueOnce({
      data: { session: { access_token: accessToken, user: { id: ownerID } } },
      error: null,
    }).mockResolvedValueOnce({
      data: { session: { access_token: 'refreshed-access-token', user: { id: ownerID } } },
      error: null,
    });
    const result = await UploadFile({ file });

    expect(getSession).toHaveBeenCalledTimes(2);
    expect(fetchUpload).toHaveBeenCalledTimes(1);
    const [[url, request]] = fetchUpload.mock.calls;
    expect(url.origin).toBe(new URL(projectURL).origin);
    expect(url.pathname).toBe('/functions/v1/guardedStorageUpload');
    expect(url.searchParams.get('bucket')).toBe('uploads');
    expect(url.searchParams.get('path')).toMatch(new RegExp(`^${ownerID}/[a-zA-Z0-9-]+-meal_photo\\.jpg$`));
    expect(request).toEqual({
      method: 'POST',
      headers: { apikey: 'test-anon-key', Authorization: `Bearer ${accessToken}`, 'Content-Type': 'image/jpeg' },
      body: file,
    });
    expect(request.body).toBe(file);
    expect(storageFrom).toHaveBeenCalledExactlyOnceWith('uploads');
    expect(getPublicUrl).toHaveBeenCalledExactlyOnceWith(url.searchParams.get('path'));
    expect(result).toEqual({
      bucket: 'uploads',
      path: url.searchParams.get('path'),
      file_url: `https://example.supabase.co/public/${url.searchParams.get('path')}`,
    });
  });

  it('keeps an explicitly supplied path and caps generated filenames at the endpoint limit', async () => {
    const explicit = `${ownerID}/existing_name.jpg`;
    const longFile = new File(['fixture'], 'a'.repeat(255), { type: 'image/jpeg' });

    expect((await UploadFile({ file, path: explicit })).path).toBe(explicit);
    expect((await UploadFile({ file: longFile })).path.split('/')[1]).toHaveLength(255);
  });

  it('requires authentication before dispatch without deriving a URL', async () => {
    getSession.mockResolvedValue({ data: { session: null }, error: null });

    await expect(UploadFile({ file, path: `${ownerID}/meal.jpg` })).rejects.toMatchObject({ status: 401 });
    expect(fetchUpload).not.toHaveBeenCalled();
    expect(storageFrom).not.toHaveBeenCalled();
  });

  it('surfaces a closed guard response without retrying through direct storage', async () => {
    fetchUpload.mockResolvedValue(Response.json({ error: 'Storage uploads are closed.' }, { status: 409 }));

    await expect(UploadFile({ file })).rejects.toMatchObject({ message: 'Storage uploads are closed.', status: 409 });
    expect(fetchUpload).toHaveBeenCalledTimes(1);
    expect(storageFrom).not.toHaveBeenCalled();
  });

  it('only returns a URL for an acknowledged exact path', async () => {
    fetchUpload.mockResolvedValue(Response.json({ path: `${ownerID}/wrong-path.jpg` }));

    await expect(UploadFile({ file })).rejects.toMatchObject({ status: 502 });
    expect(storageFrom).not.toHaveBeenCalled();
  });

  it.each([
    ['sign-out', null],
    ['account switch', { access_token: 'different-user-token', user: { id: 'different-owner' } }],
  ])('discards an upload acknowledged after %s', async (_change, nextSession) => {
    fetchUpload.mockImplementationOnce(async url => {
      getSession.mockResolvedValue({ data: { session: nextSession }, error: null });
      return Response.json({ path: url.searchParams.get('path') });
    });

    await expect(UploadFile({ file })).rejects.toMatchObject({ status: 401 });
    expect(fetchUpload).toHaveBeenCalledTimes(1);
    expect(storageFrom).not.toHaveBeenCalled();
  });
});
