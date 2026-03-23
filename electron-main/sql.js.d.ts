declare module 'sql.js' {
  export interface Database {
    run(sql: string, params?: any[]): void
    prepare(sql: string): Statement
    export(): Uint8Array
    close(): void
  }

  export interface Statement {
    bind(params?: any[]): boolean
    step(): boolean
    getAsObject(): any
    free(): boolean
  }

  export interface SqlJsStatic {
    Database: new (data?: ArrayLike<number>) => Database
  }

  function initSqlJs(config?: any): Promise<SqlJsStatic>

  export default initSqlJs
}
