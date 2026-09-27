/** Typed delete confirmation must match the shop name (trimmed, case-sensitive). */
export function confirmationMatches(typed: string, shopName: string): boolean {
  const name = shopName.trim();
  return name.length > 0 && typed.trim() === name;
}
