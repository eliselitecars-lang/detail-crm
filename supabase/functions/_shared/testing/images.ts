/** Small image fixtures for tests. */

const b64 = (text: string) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

/** A valid 64x32 RGB PNG. */
export const LOGO_PNG = b64(
  "iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAIAAAAt/+nTAAAATklEQVR4nO3PUQkAIBTAwJfEYCY2liH8OITBAtxm7fN1wwUNaEEDWtCAFjSgBQ1oQQNa0IAWNKAFDWhBA1rQgBY0oAUNaEEDWtCAFjx2AdmPAJekHBS4AAAAAElFTkSuQmCC",
);
