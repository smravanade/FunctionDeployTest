# Use the official Azure Functions Python base image (slim variant keeps size small)
FROM mcr.microsoft.com/azure-functions/python:4-python3.11-slim

# Azure Functions host reads from /home/site/wwwroot
ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true

# Copy requirements first for better layer caching
COPY requirements.txt /home/site/wwwroot/requirements.txt

RUN pip install --no-cache-dir -r /home/site/wwwroot/requirements.txt

# Copy the rest of the function app
COPY . /home/site/wwwroot
