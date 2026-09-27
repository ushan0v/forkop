export function insertIf<T>(condition: boolean, elements: Array<T>) {
  return condition ? elements : ([] as Array<T>);
}
