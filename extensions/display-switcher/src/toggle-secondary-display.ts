import { toggle } from "./toggle";

export default async function Command() {
  await toggle((configs) => configs.slice(1, 2));
}
