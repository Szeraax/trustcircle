CREATE TABLE [dbo].[Game]
(
  [Id] INT NOT NULL PRIMARY KEY IDENTITY(10000,1),
  [Ruid] VARCHAR(50) NULL,
  [StartTime] DATETIME2 DEFAULT (sysdatetime()) NULL,
  [EndTime] DATETIME2 NULL,
  [GuildId] VARCHAR(50) NULL,
  [LastReport] INT DEFAULT 1 NULL,
  [LastReportTime] DATETIME2 NULL,
  [InitiatorId] VARCHAR(50) NULL,
  [StatusWebhook] VARCHAR(MAX) NULL,
)

