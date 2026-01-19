from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    app_env: str = "dev"
    app_port: int = 8080

    isams_host: str = ""
    isams_batch_api_key: str = ""
    isams_rest_client_id: str = ""
    isams_rest_client_secret: str = ""
    # Phase 1: Batch credentials (Batch-only MVP)
    isams_batch_client_id: str = ""
    isams_batch_client_secret: str = ""

    # Optional transport settings
    isams_timeout_seconds: int = 30
    isams_verify_ssl: bool = True


    class Config:
        env_file = ".env"
        case_sensitive = False

settings = Settings()
