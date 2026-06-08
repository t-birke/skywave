// Browser-side image processing shared between website surfaces. Same
// recipe as the chat profile form (skywaveProfileFormRenderer._resizeAvatar)
// — square center-crop, 512×512 JPEG q=0.5 — so an avatar uploaded via
// chat looks identical to one uploaded via the website.

export const AVATAR_OUTPUT_SIZE = 512;
export const AVATAR_OUTPUT_QUALITY = 0.5;
export const MAX_AVATAR_BYTES = 20 * 1024 * 1024;  // sanity bound on input

/**
 * Read a File (from <input type="file"> change event), decode it,
 * crop+resize to 512×512 JPEG, return a `data:image/jpeg;base64,…` URL.
 * Rejects on read/decode failure or files over MAX_AVATAR_BYTES.
 */
export function fileToAvatarBase64(file) {
    return new Promise((resolve, reject) => {
        if (!file) return reject(new Error('no_file'));
        if (file.size > MAX_AVATAR_BYTES) return reject(new Error('file_too_large'));

        const reader = new FileReader();
        reader.onerror = () => reject(new Error('read_failed'));
        reader.onload = () => {
            const img = new Image();
            img.onerror = () => reject(new Error('decode_failed'));
            img.onload = () => {
                try {
                    resolve(_resizeToDataUrl(img));
                } catch (e) {
                    reject(e);
                }
            };
            img.src = reader.result;
        };
        reader.readAsDataURL(file);
    });
}

function _resizeToDataUrl(img) {
    const canvas = document.createElement('canvas');
    canvas.width = AVATAR_OUTPUT_SIZE;
    canvas.height = AVATAR_OUTPUT_SIZE;
    const ctx = canvas.getContext('2d');
    const shortSide = Math.min(img.width, img.height);
    const startX = (img.width - shortSide) / 2;
    const startY = (img.height - shortSide) / 2;
    ctx.drawImage(
        img,
        startX, startY, shortSide, shortSide,
        0, 0, AVATAR_OUTPUT_SIZE, AVATAR_OUTPUT_SIZE
    );
    return canvas.toDataURL('image/jpeg', AVATAR_OUTPUT_QUALITY);
}
